# test_promise_edge_cases.gd
# GUT (9.x / Godot 4) edge-case suite for GD Promise addon — companion to
# test_promise.gd. That file covers the public API; this one covers
# gaps identified in the coverage audit:
#
#   1. Reentrancy   – settling / attaching / cancelling from inside handlers
#                     that are currently being dispatched.
#   2. Fan-out      – multiple handlers and multiple await-ers on one promise.
#   3. Flattening   – promise-of-promise chains, pending adoption, and the
#                     self-resolution deadlock.
#   4. Stress       – long chains and large combinator inputs, plus the
#                     documented recursion-depth limit of each().
#   5. Signal arity – zero-arg signals, and the multi-arg hazard (pending).
#   6. Lifetime     – emitter freed while a from_signal promise is pending.
#
# Same ground rules as the main suite: nothing here triggers a hard script
# error. Paths that WOULD (multi-arg signal emission, cancel-after-free) are
# left pending instead of executed.

extends GutTest


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

class MultiEmitter:
	extends RefCounted
	signal ping
	signal fired(value)


class NodeEmitter:
	extends Node
	signal fired(value)


func _deferred() -> Dictionary:
	var d := {}
	d["promise"] = Promise.new_promise(func(res, rej):
		d["resolve"] = res
		d["reject"]  = rej
	)
	return d


# ---------------------------------------------------------------------------
# 1. Reentrancy
# ---------------------------------------------------------------------------

func test_handler_attached_during_dispatch_runs_immediately() -> void:
	# The library duplicate()s its queues before dispatching; a handler that
	# attaches a NEW handler to the same (now settled) promise must see it run
	# inline, before the next originally-queued handler.
	var d := _deferred()
	var order := []
	d.promise.and_then(func(v):
		order.append("first:" + str(v))
		d.promise.and_then(func(v2): order.append("nested:" + str(v2)))
	)
	d.promise.and_then(func(v): order.append("second:" + str(v)))
	d.resolve.call(1)
	assert_eq(order, ["first:1", "nested:1", "second:1"])


func test_finally_attached_from_inside_finally() -> void:
	var d := _deferred()
	var order := []
	d.promise.finally_cb(func(_s):
		order.append("outer")
		d.promise.finally_cb(func(_s2): order.append("inner"))
	)
	d.resolve.call(1)
	assert_eq(order, ["outer", "inner"])


func test_settling_another_promise_from_inside_a_handler() -> void:
	var d1 := _deferred()
	var d2 := _deferred()
	var got := []
	d2.promise.and_then(func(v): got.append(v))
	d1.promise.and_then(func(v): d2.resolve.call(v * 2))
	d1.resolve.call(21)
	assert_eq(got, [42])
	assert_eq(d2.promise.get_status(), Promise.Status.RESOLVED)


func test_cancelling_a_sibling_from_inside_a_handler() -> void:
	var d1 := _deferred()
	var d2 := _deferred()
	var hook_called := [false]
	var d3 := Promise.new_promise(func(_res, _rej, on_cancel):
		on_cancel.call(func(): hook_called[0] = true)
	)
	d1.promise.and_then(func(_v):
		d2.promise.cancel()
		d3.cancel()
	)
	d1.resolve.call(1)
	assert_eq(d2.promise.get_status(), Promise.Status.CANCELLED)
	assert_eq(d3.get_status(), Promise.Status.CANCELLED)
	assert_true(hook_called[0])


func test_cancelling_from_inside_finally_on_rejection() -> void:
	var d1 := _deferred()
	var d2 := _deferred()
	d1.promise.finally_cb(func(_s): d2.promise.cancel())
	d1.reject.call("e")  # finally_cb marks the rejection handled
	assert_eq(d1.promise.get_status(), Promise.Status.REJECTED)
	assert_eq(d2.promise.get_status(), Promise.Status.CANCELLED)


func test_handlers_run_in_attachment_order_then_finally() -> void:
	var d := _deferred()
	var order := []
	d.promise.and_then(func(_v): order.append(1))
	d.promise.and_then(func(_v): order.append(2))
	d.promise.finally_cb(func(_s): order.append(3))
	d.promise.and_then(func(_v): order.append(4))
	d.resolve.call(0)
	# resolve queue dispatches fully (in attachment order), THEN _finalize
	# runs the finally queue — so 3 lands after 4 despite being attached first.
	assert_eq(order, [1, 2, 4, 3])


# ---------------------------------------------------------------------------
# 2. Fan-out: multiple handlers / multiple awaiters
# ---------------------------------------------------------------------------

func test_multiple_chains_from_one_promise_are_independent() -> void:
	var d := _deferred()
	var a: Promise = d.promise.and_then(func(v): return v + 1)
	var b: Promise = d.promise.and_then(func(v): return v * 10)
	var c: Promise = d.promise.catch(func(_r): return "unused")
	d.resolve.call(5)
	var ra: Array = await a.await_status()
	var rb: Array = await b.await_status()
	var rc: Array = await c.await_status()
	assert_eq(ra[1], 6)
	assert_eq(rb[1], 50)
	assert_eq(rc[1], 5, "catch passes resolved value through untouched")


func test_multiple_awaiters_all_resume_on_settle() -> void:
	var d := _deferred()
	var results := []
	var waiter := func(tag: String):
		var r: Array = await d.promise.await_status()
		results.append(tag + ":" + str(r[1]))
	waiter.call("a")
	waiter.call("b")
	waiter.call("c")
	assert_eq(results, [], "no awaiter may resume before settle")
	d.resolve.call(7)
	await wait_process_frames(1)
	assert_eq(results.size(), 3, "the one-shot _settled emission must wake every awaiter")
	assert_has(results, "a:7")
	assert_has(results, "b:7")
	assert_has(results, "c:7")


func test_await_status_is_repeatable_after_settle() -> void:
	var p := Promise.resolve("same")
	var r1: Array = await p.await_status()
	var r2: Array = await p.await_status()
	assert_eq(r1, r2)


# ---------------------------------------------------------------------------
# 3. Flattening / adoption edge cases
# ---------------------------------------------------------------------------

func test_deeply_nested_promises_flatten_to_innermost_value() -> void:
	var p := Promise.resolve(Promise.resolve(Promise.resolve("deep")))
	var r: Array = await p.await_status()
	assert_eq(r[0], Promise.Status.RESOLVED)
	assert_eq(r[1], "deep")


func test_resolving_with_pending_promise_adopts_it_later() -> void:
	var outer := _deferred()
	var inner := _deferred()
	outer.resolve.call(inner.promise)
	assert_eq(outer.promise.get_status(), Promise.Status.PENDING,
		"adopting a pending promise must not settle yet")
	inner.resolve.call("eventually")
	assert_eq(outer.promise.get_status(), Promise.Status.RESOLVED)
	var r: Array = await outer.promise.await_status()
	assert_eq(r[1], "eventually")


func test_resolving_with_promise_that_later_rejects() -> void:
	var outer := _deferred()
	var inner := _deferred()
	outer.resolve.call(inner.promise)
	outer.promise.catch(func(_r): pass)  # mark handled
	inner.reject.call("adopted-failure")
	assert_eq(outer.promise.get_status(), Promise.Status.REJECTED)
	var r: Array = await outer.promise.await_status()
	assert_eq(r[1], "adopted-failure")
	inner.promise.catch(func(_r): pass)  # inner itself also rejected; mark handled


func test_promise_resolved_with_itself_deadlocks_quietly() -> void:
	# DOCUMENTED CURRENT BEHAVIOR: resolving a promise with itself makes it
	# await its own settlement — a silent permanent PENDING, with no error
	# and no cycle detection. (JS Promises reject with a TypeError here.)
	var d := _deferred()
	d.resolve.call(d.promise)
	assert_eq(d.promise.get_status(), Promise.Status.PENDING)
	await wait_process_frames(3)
	assert_eq(d.promise.get_status(), Promise.Status.PENDING)
	d.promise.cancel()  # break the cycle so the test leaves nothing dangling


# ---------------------------------------------------------------------------
# 4. Stress / depth limits
# ---------------------------------------------------------------------------

func test_long_and_then_chain_is_stack_safe() -> void:
	# Each and_then on an already-settled promise dispatches during the call
	# and unwinds before the next link is added, so iterative chain-building
	# is O(1) stack depth.
	var p := Promise.resolve(0)
	for i in 1000:
		p = p.and_then(func(v): return v + 1)
	var r: Array = await p.await_status()
	assert_eq(r[1], 1000)


func test_fold_over_large_list_is_stack_safe() -> void:
	var sum := func(acc, v, _i): return acc + v
	var list := []
	for i in 1000:
		list.append(i)
	var r: Array = await Promise.fold(list, sum, 0).await_status()
	assert_eq(r[1], 499500)


func test_all_with_many_promises() -> void:
	var list := []
	for i in 500:
		list.append(Promise.resolve(i))
	var r: Array = await Promise.all(list).await_status()
	assert_eq(r[0], Promise.Status.RESOLVED)
	assert_eq((r[1] as Array).size(), 500)
	assert_eq(r[1][0], 0)
	assert_eq(r[1][499], 499)


func test_all_settled_with_many_promises() -> void:
	var list := []
	for i in 300:
		list.append(Promise.resolve(i) if i % 2 == 0 else Promise.reject(i))
	var p := Promise.all_settled(list)
	var r: Array = await p.await_status()
	var fates: Array = r[1]
	assert_eq(fates.size(), 300)
	assert_eq(fates[0], Promise.Status.RESOLVED)
	assert_eq(fates[1], Promise.Status.REJECTED)


func test_each_within_safe_recursion_depth() -> void:
	# KNOWN LIMITATION: when every element and predicate result settles
	# synchronously, _each_step recurses ~8-9 stack frames per element.
	# With GDScript's default 1024-frame call-stack limit, lists much beyond
	# ~100 elements risk a stack-overflow script error (which this suite must
	# not trigger). 50 is comfortably inside the limit; if you need each()
	# on large lists, the library would need a trampoline/iterative rewrite
	# or genuinely-async elements (a real await resets the stack).
	var double := func(v, _i): return v * 2
	var list := []
	for i in 50:
		list.append(i)
	var r: Array = await Promise.each(list, double).await_status()
	assert_eq(r[0], Promise.Status.RESOLVED)
	assert_eq((r[1] as Array).size(), 50)
	assert_eq(r[1][49], 98)


func test_each_with_async_elements_resets_the_stack() -> void:
	# A genuinely deferred element suspends the recursion, so depth is not
	# cumulative across awaits. Demonstrated with a small list + one delay.
	var passthrough := func(v, _i): return v
	var list := [1, Promise.delay(0.05).and_then_return(2), 3]
	var r: Array = await Promise.each(list, passthrough).await_status()
	assert_eq(r[1], [1, 2, 3])


# ---------------------------------------------------------------------------
# 5. Signal arity
# ---------------------------------------------------------------------------

func test_from_signal_zero_arg_signal_resolves_with_null() -> void:
	var e := MultiEmitter.new()
	var p := Promise.from_signal(e.ping)
	e.ping.emit()
	await wait_process_frames(3)
	assert_eq(p.get_status(), Promise.Status.RESOLVED)
	var r: Array = await p.await_status()
	assert_null(r[1], "zero-arg signal hits the conn's default value = null")


func test_from_signal_multi_arg_signal_hazard() -> void:
	pending("KNOWN HAZARD, not executed: from_signal's internal connection " +
		"takes exactly one (defaulted) parameter. Emitting a signal with 2+ " +
		"arguments into it produces a script error at emit time, and with no " +
		"try/catch in GDScript the promise just never settles. Use a wrapper " +
		"signal or pack values into one Dictionary/Array argument.")


# ---------------------------------------------------------------------------
# 6. Emitter lifetime
# ---------------------------------------------------------------------------

func test_from_signal_stays_pending_after_emitter_freed() -> void:
	var e := NodeEmitter.new()  # Node: signals work without being in the tree
	var p := Promise.from_signal(e.fired)
	assert_eq(e.fired.get_connections().size(), 1)
	e.free()
	await wait_process_frames(2)
	assert_eq(p.get_status(), Promise.Status.PENDING,
		"freed emitter can never emit; promise is silently stranded")
	# Deliberately NOT cancelling: see the pending test below.


func test_from_signal_cancel_after_emitter_freed_hazard() -> void:
	pending("KNOWN HAZARD, not executed: cancelling a from_signal promise " +
		"after its emitter has been freed makes the cancel hook call " +
		"is_connected()/disconnect() on a dead signal. Whether that errors " +
		"is Godot-version-dependent, so it is documented rather than risked. " +
		"Pair from_signal with timeout() so stranded promises settle anyway.")


# ---------------------------------------------------------------------------
# Combinators with mixed settled/pending inputs
# ---------------------------------------------------------------------------

func test_race_with_already_settled_entry_wins_instantly() -> void:
	var d := _deferred()
	var p := Promise.race([Promise.resolve("instant"), d.promise])
	assert_eq(p.get_status(), Promise.Status.RESOLVED)
	var r: Array = await p.await_status()
	assert_eq(r[1], "instant")
	d.promise.cancel()


func test_all_with_mixed_settled_and_pending() -> void:
	var d := _deferred()
	var p := Promise.all([Promise.resolve(1), d.promise])
	assert_eq(p.get_status(), Promise.Status.PENDING)
	d.resolve.call(2)
	var r: Array = await p.await_status()
	assert_eq(r[1], [1, 2])


func test_timeout_on_already_resolved_promise() -> void:
	var p := Promise.resolve("x").timeout(0.05)
	var r: Array = await p.await_status()
	assert_eq(r[0], Promise.Status.RESOLVED)
	assert_eq(r[1], "x")