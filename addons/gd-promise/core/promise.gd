# promise.gd
# A Callable-driven Promise/A+ inspired Promise implementation for Godot 4 GDScript.
# Heavily inspired by evaera's roblox-lua-promise library: https://github.com/evaera/roblox-lua-promise
#
# Design note – single-value contract:
#   Internally, _value holds exactly ONE Variant (the resolved value or rejection
#   reason).  User callbacks always receive/return that single value directly.
#   If you need to pass multiple values, wrap them in a Dictionary or Array.
#
# Cancellation model (see
# https://eryn.io/roblox-lua-promise/api/Promise#cancel):
#   * cancel() propagates DOWNWARDS: cancelling a promise cancels every
#     pending promise chained from it via and_then/catch/tap.
#   * cancel() propagates UPWARDS: a promise is cancelled when ALL of its
#     consumers are cancelled. Chaining and_then twice and cancelling only one
#     child leaves the parent (and the other child) alive.
#   * finally_cb does NOT count as a consumer, but cancellation still flows
#     through it in both directions, and its handler runs on cancellation.
#   * Resolving a promise WITH another promise (adoption) also wires
#     cancellation through to the adopted promise.
#   * all / some / any / race cancel the remaining input promises when they
#     settle — but only inputs that have no other consumers, courtesy of the
#     upward-propagation rule. timeout() therefore cancels the source promise
#     when the timeout is reached. all_settled never cancels inputs.
#   * NOTE: awaiting (await_status & friends) does NOT register a consumer.
#     A promise that is only awaited can still be cancelled out from under
#     the awaiter, which then resumes with Status.CANCELLED.
#   * Lifetime note: a pending parent and its pending children reference each
#     other (_parent/_consumers). The links are severed in _finalize(), so the
#     cycle only exists while both are pending — which is exactly when it is
#     needed. A chain that NEVER settles or cancels will leak; settle or
#     cancel your promises.
#
# Usage:
#   var p = Promise.new_promise(func(resolve, reject, on_cancel):
#       resolve.call("hello"))
#   p.and_then(func(v): print(v))   # prints "hello"

class_name Promise
extends RefCounted

# ---------------------------------------------------------------------------
# Status enum
# ---------------------------------------------------------------------------
enum Status {
	PENDING,
	RESOLVED,
	REJECTED,
	CANCELLED
}

# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------
var _status             : Status   = Status.PENDING
var _value              : Variant  = null   # single resolved value OR rejection reason
var _queued_resolve     : Array    = []     # Array[Callable(value)]
var _queued_reject      : Array    = []     # Array[Callable(reason)]
var _queued_finally     : Array    = []     # Array[Callable(Status)]
var _cancellation_hook  : Callable          # called if/when cancelled
var _parent             : Promise  = null   # upstream (for cancel propagation)
var _consumers          : Array    = []     # downstream and_then children (NOT finally)
var _unhandled_rejection: bool     = true
signal _settled                             # emitted once when status leaves PENDING

# ---------------------------------------------------------------------------
# Static constructors
# ---------------------------------------------------------------------------

## Primary constructor. executor: func(resolve, reject, on_cancel).
## The executor may declare fewer parameters; extras are simply not passed.
static func new_promise(executor: Callable) -> Promise:
	var p := Promise.new()
	p._run_executor(executor)
	return p

## Returns an already-resolved Promise carrying `value`.
## If `value` is a Promise, it is chained onto (adopted).
static func resolve(value: Variant = null) -> Promise:
	var p := Promise.new()
	p._settle_resolve(value)
	return p

## Returns an already-rejected Promise carrying `reason`.
static func reject(reason: Variant = null) -> Promise:
	var p := Promise.new()
	p._settle_reject(reason)
	return p

## Deferred constructor – executor runs on the next process frame.
## If the promise is cancelled before that frame, the executor never runs.
static func defer(executor: Callable) -> Promise:
	var p := Promise.new()
	Engine.get_main_loop().process_frame.connect(
		func():
			if p._status == Status.PENDING:
				p._run_executor(executor),
		CONNECT_ONE_SHOT
	)
	return p

## Calls callback immediately, wrapping its return value in a resolved Promise.
## If the callback returns a Promise, it is adopted.
static func try_call(callback: Callable, args: Array = []) -> Promise:
	var p := Promise.new()
	p._settle_resolve(callback.callv(args))
	return p

## Returns a Callable that, when called with (args: Array), returns a Promise.
static func promisify(callback: Callable) -> Callable:
	return func(args: Array = []) -> Promise:
		return Promise.try_call(callback, args)

# ---------------------------------------------------------------------------
# Combinators
# ---------------------------------------------------------------------------

## Resolves with an Array of values once ALL promises resolve.
## Rejects immediately on the first rejection; remaining pending inputs are
## then cancelled if they have no other consumers.
static func all(promises: Array) -> Promise:
	if promises.is_empty():
		return Promise.resolve([])
	return Promise.new_promise(func(res: Callable, rej: Callable, on_cancel: Callable):
		var results := []
		results.resize(promises.size())
		var count := [0]
		var done  := [false]
		var children := []
		var cancel_children := func():
			for c in children:
				(c as Promise).cancel()
		on_cancel.call(cancel_children)
		for i in promises.size():
			var idx := i
			children.append((promises[idx] as Promise).and_then(
				func(v):
					if done[0]: return
					results[idx] = v
					count[0] += 1
					if count[0] >= promises.size():
						done[0] = true
						res.call(results),
				func(r):
					if done[0]: return
					done[0] = true
					# Cancel losers BEFORE settling: settling emits _settled,
					# which resumes awaiters synchronously — they must observe
					# the propagated cancellations.
					cancel_children.call()
					rej.call(r)
			))
		if done[0]:
			cancel_children.call()
	)

## Resolves with an Array of the first `count` values to resolve, in arrival
## order. Rejects if too many promises reject to make `count` possible.
## On settle, remaining pending inputs are cancelled if they have no other
## consumers.
static func some(promises: Array, count: int) -> Promise:
	if count == 0:
		return Promise.resolve([])
	return Promise.new_promise(func(res: Callable, rej: Callable, on_cancel: Callable):
		var results  := []
		var resolved := [0]
		var rejected := [0]
		var done     := [false]
		var children := []
		var cancel_children := func():
			for c in children:
				(c as Promise).cancel()
		on_cancel.call(cancel_children)
		for pr: Promise in promises:
			children.append(pr.and_then(
				func(v):
					if done[0]: return
					resolved[0] += 1
					results.append(v)
					if resolved[0] >= count:
						done[0] = true
						# Cancel before settle (see all() for why).
						cancel_children.call()
						res.call(results),
				func(r):
					if done[0]: return
					rejected[0] += 1
					if promises.size() - rejected[0] < count:
						done[0] = true
						cancel_children.call()
						rej.call(r)
			))
		if done[0]:
			cancel_children.call()
	)

## Resolves with the first value to resolve; rejects only if ALL reject.
## Losers are cancelled if they have no other consumers (via some()).
static func any(promises: Array) -> Promise:
	return Promise.some(promises, 1).and_then(func(arr): return arr[0])

## Resolves or rejects with whichever promise settles first.
## Losers are cancelled if they have no other consumers.
static func race(promises: Array) -> Promise:
	return Promise.new_promise(func(res: Callable, rej: Callable, on_cancel: Callable):
		var done := [false]
		var children := []
		var cancel_children := func():
			for c in children:
				(c as Promise).cancel()
		on_cancel.call(cancel_children)
		for pr: Promise in promises:
			children.append(pr.and_then(
				func(v):
					if done[0]: return
					done[0] = true
					# Cancel before settle (see all() for why).
					cancel_children.call()
					res.call(v),
				func(r):
					if done[0]: return
					done[0] = true
					cancel_children.call()
					rej.call(r)
			))
		if done[0]:
			cancel_children.call()
	)

## Resolves with an Array of Status values once every promise has settled.
## Equivalent to mapping finally_cb over the inputs: never cancels them and
## never consumes them.
static func all_settled(promises: Array) -> Promise:
	if promises.is_empty():
		return Promise.resolve([])
	return Promise.new_promise(func(res: Callable, _rej: Callable, _oc: Callable):
		var fates := []
		fates.resize(promises.size())
		var count := [0]
		for i in promises.size():
			var idx := i
			var f := (promises[idx] as Promise).finally_cb(func(status: Status):
				fates[idx] = status
				count[0]  += 1
				if count[0] >= promises.size():
					res.call(fates)
			)
			# finally_cb passes rejections through; all_settled itself is the
			# observer, so silence the pass-through child's unhandled warning.
			f._unhandled_rejection = false
	)

## Processes each element of `list` serially through `predicate(value, index)`.
## Each predicate call may return a Promise or a plain value.
## Resolves with an Array of the predicate return values.
##
## evaera-aligned behavior:
##   * An input element that is already CANCELLED rejects each() with an
##     ALREADY_CANCELLED PromiseError.
##   * Cancelling the each() promise stops iteration and cancels the
##     currently-active promise (which propagates to its source if it has no
##     other consumers). Untouched input promises are left alone.
##
## Implementation note: synchronously-settling elements are processed in a
## loop (trampoline), so list size is NOT limited by the call-stack depth.
static func each(list: Array, predicate: Callable) -> Promise:
	return Promise.new_promise(func(res: Callable, rej: Callable, on_cancel: Callable):
		var results := []
		results.resize(list.size())
		var state := { "cancelled": false, "active": null }
		on_cancel.call(func():
			state.cancelled = true
			if state.active != null:
				(state.active as Promise).cancel()
		)
		_each_step(list, predicate, results, 0, res, rej, state)
	)

static func _each_step(list: Array, predicate: Callable, results: Array,
		start: int, res: Callable, rej: Callable, state: Dictionary) -> void:
	var i := start
	while i < list.size():
		if state.cancelled:
			return
		var element: Variant = list[i]
		var out: Promise
		if element is Promise:
			out = (element as Promise).and_then(func(v): return predicate.call(v, i))
		else:
			var r: Variant = predicate.call(element, i)
			out = r if r is Promise else Promise.resolve(r)

		if out._status == Status.RESOLVED:
			# Fast path: keep looping instead of recursing (stack-safe).
			results[i] = out._value
			i += 1
			continue
		if out._status == Status.CANCELLED:
			rej.call(PromiseError.new("Promise is cancelled",
					PromiseError.Kind.ALREADY_CANCELLED))
			return
		# PENDING (suspend until it settles) or REJECTED (settles the attach
		# synchronously). Either way, this call frame ends here.
		var idx := i
		state.active = out
		out.and_then(
			func(v):
				state.active = null
				results[idx] = v
				_each_step(list, predicate, results, idx + 1, res, rej, state),
			func(r):
				state.active = null
				rej.call(r)
		)
		return
	res.call(results)

## Reduces `list` to a single value using `reducer(accumulator, element, index)`.
## Reducer may return a plain value or a Promise.
static func fold(list: Array, reducer: Callable, initial_value: Variant) -> Promise:
	var acc := Promise.resolve(initial_value)
	for i in list.size():
		var idx   := i
		var value: Variant = list[idx]
		acc = acc.and_then(func(prev):
			if value is Promise:
				return (value as Promise).and_then(func(v): return reducer.call(prev, v, idx))
			return reducer.call(prev, value, idx)
		)
	return acc

## Calls `callback` up to `times` extra times until it returns a resolving Promise.
static func retry(callback: Callable, times: int, args: Array = []) -> Promise:
	return Promise.try_call(callback, args).catch(func(r):
		if times > 0:
			return Promise.retry(callback, times - 1, args)
		return Promise.reject(r)
	)

## Like retry, but waits `seconds` between attempts.
static func retry_with_delay(callback: Callable, times: int,
		seconds: float, args: Array = []) -> Promise:
	return Promise.try_call(callback, args).catch(func(r):
		if times > 0:
			return Promise.delay(seconds).and_then(func(_v):
				return Promise.retry_with_delay(callback, times - 1, seconds, args)
			)
		return Promise.reject(r)
	)

## Resolves after `seconds` seconds with the elapsed time as the value.
## Cancelling the promise makes the eventual timer fire a no-op (SceneTreeTimer
## itself cannot be aborted, but the settle is ignored once cancelled).
static func delay(seconds: float) -> Promise:
	return Promise.new_promise(func(res: Callable, _rej: Callable, _on_cancel: Callable):
		var tree  := Engine.get_main_loop() as SceneTree
		var timer := tree.create_timer(seconds)
		timer.timeout.connect(func(): res.call(seconds), CONNECT_ONE_SHOT)
	)

## Resolves with the first signal emission that satisfies `predicate` (if provided).
## The resolved value is the first argument emitted by the signal.
static func from_signal(sig: Signal, predicate: Callable = Callable()) -> Promise:
	return Promise.new_promise(func(res: Callable, _rej: Callable, on_cancel: Callable):
		# A helper dictionary holds the Callable reference, bypassing the
		# "capture before assignment" issue.
		var context := { "conn": Callable() }

		context.conn = func(value: Variant = null):
			var ok := true
			if predicate.is_valid():
				ok = predicate.call(value)

			if ok:
				if sig.is_connected(context.conn):
					sig.disconnect(context.conn)
				res.call(value)

		sig.connect(context.conn, CONNECT_DEFERRED)

		on_cancel.call(func():
			if sig.is_connected(context.conn):
				sig.disconnect(context.conn)
		)
	)

# ---------------------------------------------------------------------------
# Instance chaining
# ---------------------------------------------------------------------------

## Core chaining method. Both handlers are optional.
## on_success: func(value) -> any   – called when this promise resolves.
## on_failure: func(reason) -> any  – called when this promise rejects.
## Either handler may return a plain value or a Promise (which is adopted).
## The returned promise is registered as a CONSUMER of this one: cancelling
## it propagates upward when it is the last consumer; cancelling this promise
## propagates downward to it.
func and_then(on_success: Callable = Callable(),
		on_failure: Callable = Callable()) -> Promise:
	_unhandled_rejection = false

	if _status == Status.CANCELLED:
		var p := Promise.new()
		p._status = Status.CANCELLED
		return p

	var child := Promise.new_promise(func(res: Callable, rej: Callable, on_cancel: Callable):
		var ok_cb:   Callable = _wrap_handler(on_success, res) \
				if on_success.is_valid() else res
		var fail_cb: Callable = _wrap_handler(on_failure, res) \
				if on_failure.is_valid() else rej

		match _status:
			Status.PENDING:
				_queued_resolve.append(ok_cb)
				_queued_reject.append(fail_cb)
				on_cancel.call(func():
					_queued_resolve.erase(ok_cb)
					_queued_reject.erase(fail_cb)
				)
			Status.RESOLVED:
				ok_cb.call(_value)
			Status.REJECTED:
				fail_cb.call(_value)
	)
	if _status == Status.PENDING and child._status == Status.PENDING:
		child._parent = self
		_consumers.append(child)
	return child

## Shorthand: and_then with only a failure handler.
func catch(on_failure: Callable) -> Promise:
	return and_then(Callable(), on_failure)

## Runs `handler(Status)` regardless of outcome (resolve, reject, or cancel).
##
## The returned Promise:
##   * resolves with the SAME value this promise resolves with,
##   * rejects with the SAME reason this promise rejects with,
##   * is cancelled if this promise is cancelled (after the handler runs).
## The handler's return value is discarded — unless it is a Promise, in which
## case we wait for it (discarding its value), and if it REJECTS, the returned
## Promise rejects with that error instead.
##
## finally_cb does NOT register as a consumer: it never keeps this promise
## alive against cancellation. Cancellation still propagates through it in
## both directions.
func finally_cb(handler: Callable = Callable()) -> Promise:
	_unhandled_rejection = false
	var child := Promise.new()
	# Wire for cancel propagation through (not consumption of) this promise.
	child._parent = self

	var cb := func(status: Status):
		var finish := func():
			match status:
				Status.RESOLVED:
					child._settle_resolve(_value)
				Status.REJECTED:
					child._settle_reject(_value)
				_:
					child.cancel()
		if not handler.is_valid():
			finish.call()
			return
		var r: Variant = handler.call(status)
		if r is Promise:
			(r as Promise).and_then(
				func(_v): finish.call(),
				func(e):  child._settle_reject(e)
			)
		else:
			finish.call()

	match _status:
		Status.PENDING:
			_queued_finally.append(cb)
		_:
			cb.call(_status)
	return child

## Calls `handler(value)` as a side-effect; passes the original value through.
## If `handler` returns a Promise, waits for it before continuing.
func tap(handler: Callable) -> Promise:
	return and_then(func(v):
		var r: Variant = handler.call(v)
		if r is Promise:
			return (r as Promise).and_then(func(_x): return v)
		return v
	)

## Discards the resolved value and calls `callback` with preset `args`.
## The next promise resolves with the callback's return value.
func and_then_call(callback: Callable, args: Array = []) -> Promise:
	return and_then(func(_v): return callback.callv(args))

## Discards the resolved value and resolves the next promise with `value`.
func and_then_return(value: Variant) -> Promise:
	return and_then(func(_v): return value)

## Like and_then_call but uses finally_cb (runs on resolve, reject, or cancel).
## NOTE: the callback's return value is DISCARDED — the
## returned promise passes this promise's outcome through unchanged, unless
## the callback returns a rejecting Promise.
func finally_call(callback: Callable, args: Array = []) -> Promise:
	return finally_cb(func(_s): return callback.callv(args))

## Sugar for finally_cb(func(_s): return value).
## NOTE: since finally discards handler return values,
## `value` never reaches the chain — the original outcome passes through.
## Kept for API parity; prefer and_then_return to inject a value.
func finally_return(value: Variant) -> Promise:
	return finally_cb(func(_s): return value)

## Rejects with a TIMED_OUT PromiseError if not resolved within `seconds`.
## Pass `rejection_value` to use a custom rejection reason instead.
## NOTE: if the timeout is reached, this promise is CANCELLED
## (when it has no other consumers).
func timeout(seconds: float, rejection_value: Variant = null) -> Promise:
	var reason: Variant = rejection_value if rejection_value != null else \
		PromiseError.new("Timed out after %s seconds" % seconds, PromiseError.Kind.TIMED_OUT)
	return Promise.race([
		Promise.delay(seconds).and_then(func(_v): return Promise.reject(reason)),
		self
	])

## If already resolved, chains immediately. Otherwise rejects with
## NOT_RESOLVED_IN_TIME (or a custom `rejection_value`).
func now(rejection_value: Variant = null) -> Promise:
	if _status == Status.RESOLVED:
		return and_then(func(v): return v)
	var reason: Variant = rejection_value if rejection_value != null else \
		PromiseError.new("Promise was not resolved in time for :now()",
				PromiseError.Kind.NOT_RESOLVED_IN_TIME)
	return Promise.reject(reason)

## Cancels this promise, preventing it from resolving or rejecting.
## No-op if already settled.
## Propagates DOWNWARD to all pending consumers, and UPWARD to the parent
## (which cancels itself only once it has no remaining consumers).
func cancel() -> void:
	if _status != Status.PENDING:
		return
	_status = Status.CANCELLED
	if _cancellation_hook.is_valid():
		_cancellation_hook.call()
	if _parent != null:
		_parent._consumer_cancelled(self)
	for child: Promise in _consumers.duplicate():
		(child as Promise).cancel()
	_finalize()

## Returns the current Status.
func get_status() -> Status:
	return _status

## Waits until the promise settles, then returns [Status, value].
## Call with `await` inside an async func:
##   var arr = await my_promise.await_status()
## NOTE: awaiting does not register a consumer; the promise can still be
## cancelled while awaited (the awaiter resumes with Status.CANCELLED).
func await_status() -> Array:
	_unhandled_rejection = false
	if _status == Status.PENDING:
		await _settled
	return [_status, _value]

## Convenience wrapper: returns [resolved_bool, value].
func await_result() -> Array:
	var s: Array = await await_status()
	return [s[0] == Status.RESOLVED, s[1]]

func await_resolved() -> bool:
	_unhandled_rejection = false
	if _status == Status.PENDING:
		await _settled
	if _status == Status.RESOLVED:
		return true
	return false

## Asserts that the Promise resolves. push_error is called if rejected or cancelled.
## Can be called without await — runs as a background coroutine and returns the
## resolved value if awaited, or null when called fire-and-forget.
##   promise.expect()               # fire-and-forget: errors on rejection
##   var v = await promise.expect() # yields until settled, returns value
func expect() -> Variant:
	_unhandled_rejection = false
	if _status == Status.PENDING:
		await _settled
	if _status == Status.RESOLVED:
		return _value
	if _status == Status.REJECTED:
		push_error("Promise.expect(): rejected with %s" % str(_value))
	else:
		push_error("Promise.expect(): Promise was cancelled")
	return null

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

func _run_executor(executor: Callable) -> void:
	var res := func(v: Variant = null): _settle_resolve(v)
	var rej := func(r: Variant = null): _settle_reject(r)
	var on_cancel := func(hook: Callable = Callable()):
		if hook.is_valid():
			if _status == Status.CANCELLED:
				hook.call()
			else:
				_cancellation_hook = hook
		return _status == Status.CANCELLED

	# --- FLEXIBLE CALL LOGIC ---
	var args = [res, rej, on_cancel]
	# Only pass the number of arguments the lambda actually asks for.
	var count = executor.get_argument_count()
	# If count is -1, it's a built-in or variadic, so we pass all.
	var final_args = args if count < 0 else args.slice(0, count)
	var result: Variant = executor.callv(final_args)
	# ---------------------------

	# An executor returning a Promise chains onto it (no-op if the executor
	# already settled this promise via res/rej).
	if result is Promise:
		_settle_resolve(result)

## Wraps a user handler so its return value feeds the next promise in the
## chain. Promise return values are adopted by _settle_resolve, which also
## wires cancellation through to them.
func _wrap_handler(handler: Callable, res: Callable) -> Callable:
	return func(value: Variant):
		# Check whether the handler wants the value or not.
		var count = handler.get_argument_count()
		var r: Variant = handler.call() if count == 0 else handler.call(value)
		res.call(r)

func _settle_resolve(value: Variant) -> void:
	if _status != Status.PENDING:
		return
	# If resolving with another Promise, chain onto it instead of settling now.
	if value is Promise:
		if value == self:
			# Self-resolution would await its own settlement forever.
			# (JS rejects with a TypeError here; we reject with a PromiseError.)
			_settle_reject(PromiseError.new(
				"Cannot resolve a Promise with itself",
				PromiseError.Kind.EXECUTION_ERROR))
			return
		var bridge := (value as Promise).and_then(
			func(v): _settle_resolve(v),
			func(r): _settle_reject(r)
		)
		# Wire cancellation: cancelling this promise propagates through the
		# bridge to the adopted promise (if it has no other consumers).
		if bridge._status == Status.PENDING:
			_parent = bridge
			bridge._consumers.append(self)
		return
	_status = Status.RESOLVED
	_value  = value
	for cb: Callable in _queued_resolve.duplicate():
		cb.call(_value)
	_finalize()

func _settle_reject(reason: Variant) -> void:
	if _status != Status.PENDING:
		return
	_status = Status.REJECTED
	_value  = reason
	if _queued_reject.size() > 0:
		for cb: Callable in _queued_reject.duplicate():
			cb.call(_value)
	else:
		Engine.get_main_loop().process_frame.connect(func():
			if _unhandled_rejection:
				push_warning("Unhandled Promise rejection: %s" % str(_value))
		, CONNECT_ONE_SHOT)
	_finalize()

func _finalize() -> void:
	for cb: Callable in _queued_finally.duplicate():
		cb.call(_status)
	_queued_resolve.clear()
	_queued_reject.clear()
	_queued_finally.clear()
	# Sever propagation links: breaks the parent<->child reference cycle the
	# moment it is no longer needed.
	_consumers.clear()
	_parent = null
	emit_signal("_settled")

## Called by a (former) consumer when it is cancelled. Once the last consumer
## is gone, this promise cancels itself (upward propagation).
## Note: finally children are never IN _consumers, so a lone cancelled finally
## child finds the list empty and cancels this promise — exactly the
## "can cancel its parent if it had no other consumers" rule.
func _consumer_cancelled(consumer: Promise) -> void:
	if _status != Status.PENDING:
		return
	_consumers.erase(consumer)
	if _consumers.is_empty():
		cancel()