# promise.gd
# A Callable-driven Promise/A+ inspired Promise implementation for Godot 4 GDScript.
# Heavily inspired by evaera's roblox-lua-promise library: https://github.com/evaera/roblox-lua-promise
#
# Design note – single-value contract:
#   Internally, _value holds exactly ONE Variant (the resolved value or rejection
#   reason).  User callbacks always receive/return that single value directly.
#   This avoids all Array-packing/callv mismatches that plague multi-value designs
#   in GDScript. If you need to pass multiple values, wrap them in a Dictionary
#   or Array yourself.
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
var _consumers          : Array    = []     # downstream promises
var _unhandled_rejection: bool     = true
signal _settled                             # emitted once when status leaves PENDING

# ---------------------------------------------------------------------------
# Static constructors
# ---------------------------------------------------------------------------

## Primary constructor. executor: func(resolve, reject, on_cancel).
static func new_promise(executor: Callable) -> Promise:
	var p := Promise.new()
	p._run_executor(executor)
	return p

## Returns an already-resolved Promise carrying `value`.
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
static func defer(executor: Callable) -> Promise:
	var p := Promise.new()
	Engine.get_main_loop().process_frame.connect(
		func(): p._run_executor(executor),
		CONNECT_ONE_SHOT
	)
	return p

## Calls callback immediately, wrapping its return value in a resolved Promise.
static func try_call(callback: Callable, args: Array = []) -> Promise:
	var p := Promise.new()
	var result: Variant = callback.callv(args)
	if result is Promise:
		(result as Promise).and_then(
			func(v): p._settle_resolve(v),
			func(r): p._settle_reject(r)
		)
	else:
		p._settle_resolve(result)
	return p

## Returns a Callable that, when called with (args: Array), returns a Promise.
static func promisify(callback: Callable) -> Callable:
	return func(args: Array = []) -> Promise:
		return Promise.try_call(callback, args)

# ---------------------------------------------------------------------------
# Combinators
# ---------------------------------------------------------------------------

## Resolves with an Array of values once ALL promises resolve.
## Rejects immediately on the first rejection.
static func all(promises: Array) -> Promise:
	if promises.is_empty():
		return Promise.resolve([])
	return Promise.new_promise(func(res: Callable, rej: Callable, _oc: Callable):
		var results := []
		results.resize(promises.size())
		var count := [0]
		var done  := [false]
		for i in promises.size():
			var idx := i
			(promises[idx] as Promise).and_then(
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
					rej.call(r)
			)
	)

## Resolves with an Array of the first `count` values to resolve.
## Rejects if too many promises reject to make `count` impossible.
static func some(promises: Array, count: int) -> Promise:
	if count == 0:
		return Promise.resolve([])
	return Promise.new_promise(func(res: Callable, rej: Callable, _oc: Callable):
		var results  := []
		var resolved := [0]
		var rejected := [0]
		var done     := [false]
		for pr: Promise in promises:
			pr.and_then(
				func(v):
					if done[0]: return
					resolved[0] += 1
					results.append(v)
					if resolved[0] >= count:
						done[0] = true
						res.call(results),
				func(r):
					if done[0]: return
					rejected[0] += 1
					if promises.size() - rejected[0] < count:
						done[0] = true
						rej.call(r)
			)
	)

## Resolves with the first value to resolve; rejects only if ALL reject.
static func any(promises: Array) -> Promise:
	return Promise.some(promises, 1).and_then(func(arr): return arr[0])

## Resolves or rejects with whichever promise settles first.
static func race(promises: Array) -> Promise:
	return Promise.new_promise(func(res: Callable, rej: Callable, _oc: Callable):
		var done := [false]
		for pr: Promise in promises:
			pr.and_then(
				func(v):
					if done[0]: return
					done[0] = true
					res.call(v),
				func(r):
					if done[0]: return
					done[0] = true
					rej.call(r)
			)
	)

## Resolves with an Array of Status values once every promise has settled.
static func all_settled(promises: Array) -> Promise:
	if promises.is_empty():
		return Promise.resolve([])
	return Promise.new_promise(func(res: Callable, _rej: Callable, _oc: Callable):
		var fates := []
		fates.resize(promises.size())
		var count := [0]
		for i in promises.size():
			var idx := i
			(promises[idx] as Promise).finally_cb(func(status: Status):
				fates[idx] = status
				count[0]  += 1
				if count[0] >= promises.size():
					res.call(fates)
			)
	)

## Processes each element of `list` serially through `predicate`.
## Each predicate call may return a Promise or a plain value.
## Resolves with an Array of the predicate return values.
static func each(list: Array, predicate: Callable) -> Promise:
	return Promise.new_promise(func(res: Callable, rej: Callable, _oc: Callable):
		var results := []
		results.resize(list.size())
		_each_step(list, predicate, results, 0, res, rej)
	)

static func _each_step(list: Array, predicate: Callable, results: Array,
		i: int, res: Callable, rej: Callable) -> void:
	if i >= list.size():
		res.call(results)
		return
	var element: Variant = list[i]
	var out: Promise
	if element is Promise:
		out = (element as Promise).and_then(func(v): return predicate.call(v, i))
	else:
		var r: Variant = predicate.call(element, i)
		out = r if r is Promise else Promise.resolve(r)
	out.and_then(
		func(v):
			results[i] = v
			_each_step(list, predicate, results, i + 1, res, rej),
		func(r): rej.call(r)
	)

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
static func delay(seconds: float) -> Promise:
	return Promise.new_promise(func(res: Callable, _rej: Callable, on_cancel: Callable):
		var tree  := Engine.get_main_loop() as SceneTree
		var timer := tree.create_timer(seconds)
		on_cancel.call(func(): pass)
		timer.timeout.connect(func(): res.call(seconds), CONNECT_ONE_SHOT)
	)

## Resolves with the first signal emission that satisfies `predicate` (if provided).
## The resolved value is the first argument emitted by the signal.
static func from_signal(sig: Signal, predicate: Callable = Callable()) -> Promise:
	return Promise.new_promise(func(res: Callable, _rej: Callable, on_cancel: Callable):
		# We define a helper dictionary to hold the reference to the callable
		# This bypasses the "capture before assignment" issue
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
## Either handler may return a plain value or a Promise.
func and_then(on_success: Callable = Callable(),
		on_failure: Callable = Callable()) -> Promise:
	_unhandled_rejection = false

	if _status == Status.CANCELLED:
		var p := Promise.new()
		p._status = Status.CANCELLED
		return p

	return Promise.new_promise(func(res: Callable, rej: Callable, on_cancel: Callable):
		var ok_cb:   Callable = _wrap_handler(on_success, res, rej) \
				if on_success.is_valid() else res
		var fail_cb: Callable = _wrap_handler(on_failure, res, rej) \
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

## Shorthand: and_then with only a failure handler.
func catch(on_failure: Callable) -> Promise:
	return and_then(Callable(), on_failure)

## Runs `handler(Status)` regardless of outcome.
## The returned Promise re-resolves/rejects with the original status,
## unless `handler` itself returns a rejecting Promise.
func finally_cb(handler: Callable = Callable()) -> Promise:
	_unhandled_rejection = false
	return Promise.new_promise(func(res: Callable, rej: Callable, _oc: Callable):
		var cb := func(status: Status):
			if not handler.is_valid():
				res.call(status)
				return
			var r: Variant = handler.call(status)
			if r is Promise:
				(r as Promise).and_then(
					func(_v): res.call(status),
					func(e):  rej.call(e)
				)
			else:
				res.call(status)
		match _status:
			Status.PENDING:
				_queued_finally.append(cb)
			_:
				cb.call(_status)
	)

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
func and_then_call(callback: Callable, args: Array = []) -> Promise:
	return and_then(func(_v): return callback.callv(args))

## Discards the resolved value and resolves the next promise with `value`.
func and_then_return(value: Variant) -> Promise:
	return and_then(func(_v): return value)

## Like and_then_call but uses finally_cb (runs on resolve, reject, or cancel).
func finally_call(callback: Callable, args: Array = []) -> Promise:
	return finally_cb(func(_s): return callback.callv(args))

## Like and_then_return but uses finally_cb.
func finally_return(value: Variant) -> Promise:
	return finally_cb(func(_s): return value)

## Rejects with a TIMED_OUT PromiseError if not resolved within `seconds`.
## Pass `rejection_value` to use a custom rejection reason instead.
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

## Cancels this promise. Propagates upward (parent) and downward (consumers).
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
##   promise.expect()              # fire-and-forget: errors on rejection
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
	# Only pass the number of arguments the lambda actually asks for
	var count = executor.get_argument_count()
	
	# If count is -1, it's a built-in or variadic, so we pass all.
	# Otherwise, we slice the array to match the user's signature.
	var final_args = args if count < 0 else args.slice(0, count)
	
	var result: Variant = executor.callv(final_args)
	# ---------------------------

	if result is Promise:
		(result as Promise).and_then(
			func(v): _settle_resolve(v),
			func(r): _settle_reject(r)
		)

## Wraps a user handler so its return value feeds the next promise in the chain.
func _wrap_handler(handler: Callable, res: Callable, rej: Callable) -> Callable:
	return func(value: Variant):
		# Check if the handler wants the value or not
		var count = handler.get_argument_count()
		var r: Variant
		if count == 0:
			r = handler.call()
		else:
			r = handler.call(value)
			
		if r is Promise:
			(r as Promise).and_then(
				func(v): res.call(v),
				func(e): rej.call(e)
			)
		else:
			res.call(r)

func _settle_resolve(value: Variant) -> void:
	if _status != Status.PENDING:
		return
	# If resolving with another Promise, chain onto it instead of settling now.
	if value is Promise:
		(value as Promise).and_then(
			func(v): _settle_resolve(v),
			func(r): _settle_reject(r)
		)
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
	emit_signal("_settled")

func _consumer_cancelled(consumer: Promise) -> void:
	if _status != Status.PENDING:
		return
	_consumers.erase(consumer)
	if _consumers.is_empty():
		cancel()