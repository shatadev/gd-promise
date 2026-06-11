# test_promise.gd
# GUT (9.x / Godot 4) unit tests for GD Promise addon
#
# Add to your GUT test directories: e.g. res://addons/gd-promise/test/unit/
#
# Notes:
# - No test triggers a hard engine error. Rejections are always handled
#   (via handlers or await_status(), which suppresses the unhandled-rejection
#   warning), so the test log stays clean.
# - expect()-on-rejection and the unhandled-rejection warning intentionally
#   call push_error/push_warning; GUT cannot assert on those, so those two
#   behaviors are marked pending() with an explanation instead of being
#   exercised.

extends GutTest


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

class Emitter:
	extends RefCounted
	signal fired(value)


## Returns { promise, resolve, reject } so tests can settle a promise
## manually at any point.
func _deferred() -> Dictionary:
	var d := {}
	d["promise"] = Promise.new_promise(func(res, rej):
		d["resolve"] = res
		d["reject"]  = rej
	)
	return d


# ---------------------------------------------------------------------------
# Static constructors
# ---------------------------------------------------------------------------

func test_resolve_static_is_immediately_resolved() -> void:
	var p := Promise.resolve("hello")
	assert_eq(p.get_status(), Promise.Status.RESOLVED)
	var r: Array = await p.await_status()
	assert_eq(r[1], "hello")


func test_resolve_static_defaults_to_null() -> void:
	var r: Array = await Promise.resolve().await_status()
	assert_eq(r[0], Promise.Status.RESOLVED)
	assert_null(r[1])


func test_reject_static_is_immediately_rejected() -> void:
	var p := Promise.reject("bad")
	assert_eq(p.get_status(), Promise.Status.REJECTED)
	var r: Array = await p.await_status()
	assert_eq(r[1], "bad")


func test_new_promise_sync_resolve() -> void:
	var p := Promise.new_promise(func(res, _rej, _oc): res.call(42))
	assert_eq(p.get_status(), Promise.Status.RESOLVED)
	var r: Array = await p.await_status()
	assert_eq(r[1], 42)


func test_new_promise_sync_reject() -> void:
	var p := Promise.new_promise(func(_res, rej, _oc): rej.call("nope"))
	var r: Array = await p.await_status()
	assert_eq(r[0], Promise.Status.REJECTED)
	assert_eq(r[1], "nope")


func test_new_promise_executor_with_fewer_args() -> void:
	# Flexible-arity executor: only asks for `resolve`.
	var p := Promise.new_promise(func(res): res.call("minimal"))
	var r: Array = await p.await_status()
	assert_eq(r[0], Promise.Status.RESOLVED)
	assert_eq(r[1], "minimal")


func test_new_promise_executor_returning_promise_chains() -> void:
	var inner := Promise.resolve(7)
	var executor := func(): return inner
	var p := Promise.new_promise(executor)
	var r: Array = await p.await_status()
	assert_eq(r[0], Promise.Status.RESOLVED)
	assert_eq(r[1], 7)


func test_resolving_with_a_promise_adopts_its_value() -> void:
	var p := Promise.new_promise(func(res): res.call(Promise.resolve("inner")))
	var r: Array = await p.await_status()
	assert_eq(r[0], Promise.Status.RESOLVED)
	assert_eq(r[1], "inner")


func test_resolving_with_a_rejected_promise_adopts_its_rejection() -> void:
	var p := Promise.new_promise(func(res): res.call(Promise.reject("inner-err")))
	var r: Array = await p.await_status()
	assert_eq(r[0], Promise.Status.REJECTED)
	assert_eq(r[1], "inner-err")


func test_settle_is_idempotent() -> void:
	var d := _deferred()
	d.resolve.call(1)
	d.resolve.call(2)        # ignored
	d.reject.call("ignored") # ignored
	var r: Array = await d.promise.await_status()
	assert_eq(r[0], Promise.Status.RESOLVED)
	assert_eq(r[1], 1)


func test_defer_runs_executor_on_next_frame() -> void:
	var ran := [false]
	var p := Promise.defer(func(res):
		ran[0] = true
		res.call("deferred")
	)
	assert_false(ran[0], "executor must not run synchronously")
	assert_eq(p.get_status(), Promise.Status.PENDING)
	# await_status() can only return after the deferred executor has run,
	# so no frame counting is needed (and wait_frames is now physics-based).
	var r: Array = await p.await_status()
	assert_true(ran[0])
	assert_eq(r[1], "deferred")


func test_try_call_plain_return_value() -> void:
	var add := func(a, b): return a + b
	var r: Array = await Promise.try_call(add, [1, 2]).await_status()
	assert_eq(r[0], Promise.Status.RESOLVED)
	assert_eq(r[1], 3)


func test_try_call_returning_resolving_promise() -> void:
	var cb := func(): return Promise.resolve("inner-ok")
	var r: Array = await Promise.try_call(cb).await_status()
	assert_eq(r[0], Promise.Status.RESOLVED)
	assert_eq(r[1], "inner-ok")


func test_try_call_returning_rejecting_promise() -> void:
	var cb := func(): return Promise.reject("inner-fail")
	var r: Array = await Promise.try_call(cb).await_status()
	assert_eq(r[0], Promise.Status.REJECTED)
	assert_eq(r[1], "inner-fail")


func test_promisify_wraps_callable() -> void:
	var sum := func(a, b): return a + b
	var promisified := Promise.promisify(sum)
	var p: Promise = promisified.call([2, 3])
	var r: Array = await p.await_status()
	assert_eq(r[0], Promise.Status.RESOLVED)
	assert_eq(r[1], 5)


# ---------------------------------------------------------------------------
# and_then / catch chaining
# ---------------------------------------------------------------------------

func test_and_then_transforms_value() -> void:
	var p := Promise.resolve(2).and_then(func(v): return v + 3)
	var r: Array = await p.await_status()
	assert_eq(r[1], 5)


func test_and_then_returning_promise_waits_for_it() -> void:
	var p := Promise.resolve(2).and_then(func(v): return Promise.resolve(v * 10))
	var r: Array = await p.await_status()
	assert_eq(r[0], Promise.Status.RESOLVED)
	assert_eq(r[1], 20)


func test_and_then_returning_rejected_promise_rejects_chain() -> void:
	var p := Promise.resolve(1).and_then(func(_v): return Promise.reject("mid-fail"))
	var r: Array = await p.await_status()
	assert_eq(r[0], Promise.Status.REJECTED)
	assert_eq(r[1], "mid-fail")


func test_and_then_handler_with_zero_args() -> void:
	var zero := func(): return "no-args"
	var r: Array = await Promise.resolve(123).and_then(zero).await_status()
	assert_eq(r[0], Promise.Status.RESOLVED)
	assert_eq(r[1], "no-args")


func test_and_then_success_handler_skipped_on_rejection() -> void:
	var hit := [false]
	var ok := func(_v): hit[0] = true
	var r: Array = await Promise.reject("err").and_then(ok).await_status()
	assert_false(hit[0])
	assert_eq(r[0], Promise.Status.REJECTED)
	assert_eq(r[1], "err")


func test_and_then_failure_handler_recovers() -> void:
	var recover := func(reason): return "recovered:" + str(reason)
	var r: Array = await Promise.reject("e").and_then(Callable(), recover).await_status()
	assert_eq(r[0], Promise.Status.RESOLVED)
	assert_eq(r[1], "recovered:e")


func test_and_then_queued_until_parent_resolves() -> void:
	var d := _deferred()
	var got := [null]
	d.promise.and_then(func(v): got[0] = v)
	assert_null(got[0])
	d.resolve.call("late")
	assert_eq(got[0], "late")


func test_chained_transforms() -> void:
	var p := Promise.resolve(2).and_then(func(v): return v + 3)
	p = p.and_then(func(v): return Promise.resolve(v * 2))
	var r: Array = await p.await_status()
	assert_eq(r[1], 10)


func test_catch_handles_rejection() -> void:
	var recover := func(reason): return str(reason) + "-caught"
	var r: Array = await Promise.reject("boom").catch(recover).await_status()
	assert_eq(r[0], Promise.Status.RESOLVED)
	assert_eq(r[1], "boom-caught")


func test_catch_passes_resolved_value_through() -> void:
	var hit := [false]
	var handler := func(_r): hit[0] = true
	var r: Array = await Promise.resolve(5).catch(handler).await_status()
	assert_false(hit[0])
	assert_eq(r[0], Promise.Status.RESOLVED)
	assert_eq(r[1], 5)


func test_catch_returning_rejected_promise_re_rejects() -> void:
	var rethrow := func(reason): return Promise.reject(str(reason) + "!")
	var r: Array = await Promise.reject("e").catch(rethrow).await_status()
	assert_eq(r[0], Promise.Status.REJECTED)
	assert_eq(r[1], "e!")


# ---------------------------------------------------------------------------
# finally_cb and friends
# ---------------------------------------------------------------------------

func test_finally_runs_on_resolve_with_status() -> void:
	var got := [-1]
	var handler := func(s): got[0] = s
	await Promise.resolve(1).finally_cb(handler).await_status()
	assert_eq(got[0], Promise.Status.RESOLVED)


func test_finally_runs_on_reject_with_status() -> void:
	var got := [-1]
	var handler := func(s): got[0] = s
	await Promise.reject("x").finally_cb(handler).await_status()
	assert_eq(got[0], Promise.Status.REJECTED)


func test_finally_runs_on_cancel_with_status() -> void:
	var d := _deferred()
	var got := [-1]
	d.promise.finally_cb(func(s): got[0] = s)
	d.promise.cancel()
	assert_eq(got[0], Promise.Status.CANCELLED)


func test_finally_queued_until_settled() -> void:
	var d := _deferred()
	var got := [-1]
	var f: Promise = d.promise.finally_cb(func(s): got[0] = s)
	f.catch(func(_r): pass)  # finally now re-rejects with the parent's reason
	assert_eq(got[0], -1)
	d.reject.call("later")
	assert_eq(got[0], Promise.Status.REJECTED)
	assert_eq(f.get_status(), Promise.Status.REJECTED)


func test_finally_downstream_passes_value_through() -> void:
	var noop := func(_s): pass
	var r: Array = await Promise.resolve("payload").finally_cb(noop).await_status()
	# evaera v4 semantics: the finally promise resolves with the SAME value.
	assert_eq(r[0], Promise.Status.RESOLVED)
	assert_eq(r[1], "payload")


func test_finally_downstream_passes_rejection_through() -> void:
	var noop := func(_s): pass
	var r: Array = await Promise.reject("boom").finally_cb(noop).await_status()
	assert_eq(r[0], Promise.Status.REJECTED)
	assert_eq(r[1], "boom")


func test_finally_handler_returning_rejected_promise_rejects_chain() -> void:
	var bad := func(_s): return Promise.reject("finally-failed")
	var r: Array = await Promise.resolve(1).finally_cb(bad).await_status()
	assert_eq(r[0], Promise.Status.REJECTED)
	assert_eq(r[1], "finally-failed")


func test_finally_handler_returning_resolving_promise_is_awaited() -> void:
	var slow := func(_s): return Promise.delay(0.05)
	var r: Array = await Promise.resolve(1).finally_cb(slow).await_status()
	assert_eq(r[0], Promise.Status.RESOLVED)
	assert_eq(r[1], 1, "returned promise's value is discarded; parent value passes through")


func test_finally_call_runs_callback_with_args() -> void:
	var hits := []
	var cb := func(a, b): hits.append(a + b)
	var r: Array = await Promise.resolve(1).finally_call(cb, [2, 3]).await_status()
	assert_eq(hits, [5])
	assert_eq(r[1], 1, "callback return is discarded; parent value passes through")


func test_finally_return_value_is_discarded_passes_parent_value() -> void:
	# evaera semantics: finally discards handler return values entirely, so
	# finally_return's value never reaches the chain — the parent's own value
	# passes through. (Matches evaera, where finallyReturn is sugar for a
	# finally handler whose return is discarded.)
	var r: Array = await Promise.resolve("x").finally_return("ignored").await_status()
	assert_eq(r[0], Promise.Status.RESOLVED)
	assert_eq(r[1], "x")


# ---------------------------------------------------------------------------
# tap / and_then_call / and_then_return
# ---------------------------------------------------------------------------

func test_tap_side_effect_and_value_passthrough() -> void:
	var seen := []
	var spy := func(v): seen.append(v)
	var r: Array = await Promise.resolve("v").tap(spy).await_status()
	assert_eq(seen, ["v"])
	assert_eq(r[1], "v")


func test_tap_waits_for_returned_promise_then_passes_value() -> void:
	var order := []
	var slow_tap := func(v):
		order.append("tap:" + str(v))
		return Promise.delay(0.05)
	var after := func(v): order.append("then:" + str(v))
	var p := Promise.resolve("v").tap(slow_tap).and_then(after)
	await p.await_status()
	assert_eq(order, ["tap:v", "then:v"])


func test_and_then_call_discards_value_uses_args() -> void:
	var add := func(a, b): return a + b
	var r: Array = await Promise.resolve(99).and_then_call(add, [2, 3]).await_status()
	assert_eq(r[0], Promise.Status.RESOLVED)
	assert_eq(r[1], 5)


func test_and_then_return_replaces_value() -> void:
	var r: Array = await Promise.resolve("old").and_then_return("new").await_status()
	assert_eq(r[1], "new")


# ---------------------------------------------------------------------------
# timeout / now
# ---------------------------------------------------------------------------

func test_timeout_resolves_when_in_time() -> void:
	var p := Promise.delay(0.05).and_then_return("done").timeout(0.5)
	var r: Array = await p.await_status()
	assert_eq(r[0], Promise.Status.RESOLVED)
	assert_eq(r[1], "done")


func test_timeout_rejects_with_timed_out_error() -> void:
	var p := Promise.delay(0.5).timeout(0.05)
	var r: Array = await p.await_status()
	assert_eq(r[0], Promise.Status.REJECTED)
	assert_true(PromiseError.is_kind(r[1], PromiseError.Kind.TIMED_OUT))


func test_timeout_with_custom_rejection_value() -> void:
	var p := Promise.delay(0.5).timeout(0.05, "custom-timeout")
	var r: Array = await p.await_status()
	assert_eq(r[0], Promise.Status.REJECTED)
	assert_eq(r[1], "custom-timeout")


func test_now_on_resolved_promise_chains() -> void:
	var r: Array = await Promise.resolve("ready").now().await_status()
	assert_eq(r[0], Promise.Status.RESOLVED)
	assert_eq(r[1], "ready")


func test_now_on_pending_promise_rejects() -> void:
	var d := _deferred()
	var r: Array = await d.promise.now().await_status()
	assert_eq(r[0], Promise.Status.REJECTED)
	assert_true(PromiseError.is_kind(r[1], PromiseError.Kind.NOT_RESOLVED_IN_TIME))
	d.promise.cancel()  # tidy up


func test_now_with_custom_rejection_value() -> void:
	var d := _deferred()
	var r: Array = await d.promise.now("not-yet").await_status()
	assert_eq(r[1], "not-yet")
	d.promise.cancel()


# ---------------------------------------------------------------------------
# cancel
# ---------------------------------------------------------------------------

func test_cancel_sets_status_and_calls_hook() -> void:
	var called := [false]
	var p := Promise.new_promise(func(_res, _rej, on_cancel):
		on_cancel.call(func(): called[0] = true)
	)
	p.cancel()
	assert_true(called[0])
	assert_eq(p.get_status(), Promise.Status.CANCELLED)


func test_cancel_on_settled_promise_is_noop() -> void:
	var p := Promise.resolve(1)
	p.cancel()
	assert_eq(p.get_status(), Promise.Status.RESOLVED)

	var q := Promise.reject("e")
	q.catch(func(_r): pass)  # mark handled
	q.cancel()
	assert_eq(q.get_status(), Promise.Status.REJECTED)


func test_cancelled_promise_ignores_late_settle() -> void:
	var d := _deferred()
	d.promise.cancel()
	d.resolve.call("too-late")
	assert_eq(d.promise.get_status(), Promise.Status.CANCELLED)


func test_cancelling_one_of_two_children_keeps_parent_alive() -> void:
	# evaera: a promise is only cancelled when ALL consumers are cancelled.
	var d := _deferred()
	var hit_a := [false]
	var hit_b := [false]
	var a: Promise = d.promise.and_then(func(_v): hit_a[0] = true)
	var b: Promise = d.promise.and_then(func(_v): hit_b[0] = true)
	a.cancel()
	assert_eq(d.promise.get_status(), Promise.Status.PENDING,
		"one remaining consumer keeps the parent alive")
	d.resolve.call(1)
	assert_false(hit_a[0], "cancelled child's handler must not run")
	assert_true(hit_b[0], "surviving child's handler still runs")
	assert_eq(a.get_status(), Promise.Status.CANCELLED)
	assert_eq(d.promise.get_status(), Promise.Status.RESOLVED)


func test_cancelling_only_child_cancels_parent_upward() -> void:
	# evaera: cancelling the last (here: only) consumer cancels the parent.
	var d := _deferred()
	var child: Promise = d.promise.and_then(func(v): return v)
	child.cancel()
	assert_eq(child.get_status(), Promise.Status.CANCELLED)
	assert_eq(d.promise.get_status(), Promise.Status.CANCELLED)
	d.resolve.call(1)  # ignored
	assert_eq(d.promise.get_status(), Promise.Status.CANCELLED)


func test_and_then_on_cancelled_promise_returns_cancelled_promise() -> void:
	var d := _deferred()
	d.promise.cancel()
	var chained: Promise = d.promise.and_then(func(v): return v)
	assert_eq(chained.get_status(), Promise.Status.CANCELLED)


func test_cancelling_parent_cancels_children_downward() -> void:
	# evaera: cancellation propagates downwards through chained promises.
	var d := _deferred()
	var child: Promise = d.promise.and_then(func(v): return v)
	d.promise.cancel()
	assert_eq(d.promise.get_status(), Promise.Status.CANCELLED)
	assert_eq(child.get_status(), Promise.Status.CANCELLED)


func test_cancel_delay_prevents_resolution() -> void:
	var p := Promise.delay(0.05)
	p.cancel()
	assert_eq(p.get_status(), Promise.Status.CANCELLED)
	await wait_seconds(0.1)  # let the internal timer fire anyway
	assert_eq(p.get_status(), Promise.Status.CANCELLED)


# ---------------------------------------------------------------------------
# await helpers
# ---------------------------------------------------------------------------

func test_await_status_on_already_settled() -> void:
	var r: Array = await Promise.resolve("x").await_status()
	assert_eq(r, [Promise.Status.RESOLVED, "x"])


func test_await_status_waits_for_pending() -> void:
	var d := _deferred()
	get_tree().create_timer(0.05).timeout.connect(func(): d.resolve.call("late"))
	var r: Array = await d.promise.await_status()
	assert_eq(r[0], Promise.Status.RESOLVED)
	assert_eq(r[1], "late")


func test_await_result_resolved() -> void:
	var r: Array = await Promise.resolve(5).await_result()
	assert_true(r[0])
	assert_eq(r[1], 5)


func test_await_result_rejected() -> void:
	var r: Array = await Promise.reject("e").await_result()
	assert_false(r[0])
	assert_eq(r[1], "e")


func test_await_resolved_true_and_false() -> void:
	assert_true(await Promise.resolve(1).await_resolved())
	assert_false(await Promise.reject("e").await_resolved())
	var d := _deferred()
	d.promise.cancel()
	assert_false(await d.promise.await_resolved())


func test_expect_returns_value_on_resolve() -> void:
	var v: Variant = await Promise.resolve("val").expect()
	assert_eq(v, "val")


func test_expect_on_rejection_pushes_error() -> void:
	pending("expect() on a rejected/cancelled promise calls push_error by design. " +
		"GUT cannot assert on push_error, and triggering it would dirty the " +
		"error log, so this path is documented but not executed.")


func test_unhandled_rejection_warning() -> void:
	pending("A rejection with no handlers schedules push_warning on the next " +
		"frame. GUT cannot assert on push_warning, so this path is documented " +
		"but not executed. (Attaching any handler or calling await_status() " +
		"suppresses it, which every other test here relies on.)")


# ---------------------------------------------------------------------------
# Combinators: all / some / any / race / all_settled
# ---------------------------------------------------------------------------

func test_all_empty_resolves_with_empty_array() -> void:
	var r: Array = await Promise.all([]).await_status()
	assert_eq(r[0], Promise.Status.RESOLVED)
	assert_eq(r[1], [])


func test_all_resolves_with_ordered_values() -> void:
	var d1 := _deferred()
	var d2 := _deferred()
	var p := Promise.all([d1.promise, d2.promise, Promise.resolve("c")])
	d2.resolve.call("b")  # settle out of order on purpose
	d1.resolve.call("a")
	var r: Array = await p.await_status()
	assert_eq(r[0], Promise.Status.RESOLVED)
	assert_eq(r[1], ["a", "b", "c"])


func test_all_rejects_on_first_rejection() -> void:
	var d1 := _deferred()
	var d2 := _deferred()
	var p := Promise.all([d1.promise, d2.promise])
	d2.reject.call("boom")
	var r: Array = await p.await_status()
	assert_eq(r[0], Promise.Status.REJECTED)
	assert_eq(r[1], "boom")
	assert_eq(d1.promise.get_status(), Promise.Status.CANCELLED,
		"remaining input with no other consumers is auto-cancelled")


func test_some_zero_count_resolves_immediately() -> void:
	var d := _deferred()
	var r: Array = await Promise.some([d.promise], 0).await_status()
	assert_eq(r[0], Promise.Status.RESOLVED)
	assert_eq(r[1], [])
	d.promise.cancel()


func test_some_resolves_with_first_n_values() -> void:
	var d1 := _deferred()
	var d2 := _deferred()
	var d3 := _deferred()
	var p := Promise.some([d1.promise, d2.promise, d3.promise], 2)
	d3.resolve.call("third")
	d1.resolve.call("first")
	var r: Array = await p.await_status()
	assert_eq(r[0], Promise.Status.RESOLVED)
	assert_eq(r[1], ["third", "first"])  # arrival order
	assert_eq(d2.promise.get_status(), Promise.Status.CANCELLED,
		"remaining input with no other consumers is auto-cancelled")


func test_some_rejects_when_count_becomes_impossible() -> void:
	var d1 := _deferred()
	var d2 := _deferred()
	var d3 := _deferred()
	var p := Promise.some([d1.promise, d2.promise, d3.promise], 2)
	d1.reject.call("e1")  # 2 remaining, still possible
	assert_eq(p.get_status(), Promise.Status.PENDING)
	d2.reject.call("e2")  # 1 remaining < 2 -> impossible
	var r: Array = await p.await_status()
	assert_eq(r[0], Promise.Status.REJECTED)
	assert_eq(r[1], "e2")
	assert_eq(d3.promise.get_status(), Promise.Status.CANCELLED,
		"remaining input with no other consumers is auto-cancelled")


func test_any_resolves_with_first_value() -> void:
	var p := Promise.any([Promise.reject("a"), Promise.resolve("ok")])
	var r: Array = await p.await_status()
	assert_eq(r[0], Promise.Status.RESOLVED)
	assert_eq(r[1], "ok")


func test_any_rejects_when_all_reject() -> void:
	var p := Promise.any([Promise.reject("a"), Promise.reject("b")])
	var r: Array = await p.await_status()
	assert_eq(r[0], Promise.Status.REJECTED)
	assert_eq(r[1], "b")  # the rejection that made success impossible


func test_race_resolves_with_first_settler() -> void:
	var d1 := _deferred()
	var d2 := _deferred()
	var p := Promise.race([d1.promise, d2.promise])
	d2.resolve.call("winner")
	var r: Array = await p.await_status()
	assert_eq(r[0], Promise.Status.RESOLVED)
	assert_eq(r[1], "winner")
	assert_eq(d1.promise.get_status(), Promise.Status.CANCELLED,
		"loser with no other consumers is auto-cancelled")
	d1.resolve.call("loser")  # ignored: already cancelled
	assert_eq(d1.promise.get_status(), Promise.Status.CANCELLED)


func test_race_rejects_with_first_rejection() -> void:
	var d1 := _deferred()
	var d2 := _deferred()
	var p := Promise.race([d1.promise, d2.promise])
	d1.reject.call("fast-fail")
	var r: Array = await p.await_status()
	assert_eq(r[0], Promise.Status.REJECTED)
	assert_eq(r[1], "fast-fail")
	assert_eq(d2.promise.get_status(), Promise.Status.CANCELLED,
		"loser with no other consumers is auto-cancelled")


func test_all_settled_empty() -> void:
	var r: Array = await Promise.all_settled([]).await_status()
	assert_eq(r[1], [])


func test_all_settled_reports_every_status() -> void:
	var d := _deferred()
	var p := Promise.all_settled([
		Promise.resolve(1),
		Promise.reject("e"),
		d.promise,
	])
	assert_eq(p.get_status(), Promise.Status.PENDING)
	d.promise.cancel()
	var r: Array = await p.await_status()
	assert_eq(r[0], Promise.Status.RESOLVED)
	assert_eq(r[1], [
		Promise.Status.RESOLVED,
		Promise.Status.REJECTED,
		Promise.Status.CANCELLED,
	])


# ---------------------------------------------------------------------------
# each / fold
# ---------------------------------------------------------------------------

func test_each_processes_plain_values_serially() -> void:
	var seen_indices := []
	var double := func(v, i):
		seen_indices.append(i)
		return v * 2
	var r: Array = await Promise.each([1, 2, 3], double).await_status()
	assert_eq(r[0], Promise.Status.RESOLVED)
	assert_eq(r[1], [2, 4, 6])
	assert_eq(seen_indices, [0, 1, 2])


func test_each_unwraps_promise_elements() -> void:
	var double := func(v, _i): return v * 2
	var list := [Promise.resolve(1), 2, Promise.resolve(3)]
	var r: Array = await Promise.each(list, double).await_status()
	assert_eq(r[1], [2, 4, 6])


func test_each_predicate_may_return_promise() -> void:
	var async_double := func(v, _i): return Promise.resolve(v * 2)
	var r: Array = await Promise.each([1, 2], async_double).await_status()
	assert_eq(r[1], [2, 4])


func test_each_rejects_when_predicate_rejects() -> void:
	var maybe_fail := func(v, _i):
		if v == 2:
			return Promise.reject("bad-element")
		return v
	var r: Array = await Promise.each([1, 2, 3], maybe_fail).await_status()
	assert_eq(r[0], Promise.Status.REJECTED)
	assert_eq(r[1], "bad-element")


func test_fold_reduces_plain_values() -> void:
	var sum := func(acc, v, _i): return acc + v
	var r: Array = await Promise.fold([1, 2, 3], sum, 0).await_status()
	assert_eq(r[0], Promise.Status.RESOLVED)
	assert_eq(r[1], 6)


func test_fold_unwraps_promise_elements() -> void:
	var sum := func(acc, v, _i): return acc + v
	var list := [1, Promise.resolve(2), 3]
	var r: Array = await Promise.fold(list, sum, 10).await_status()
	assert_eq(r[1], 16)


func test_fold_reducer_may_return_promise() -> void:
	var async_sum := func(acc, v, _i): return Promise.resolve(acc + v)
	var r: Array = await Promise.fold([1, 2, 3], async_sum, 0).await_status()
	assert_eq(r[1], 6)


# ---------------------------------------------------------------------------
# retry / retry_with_delay / delay
# ---------------------------------------------------------------------------

func test_retry_succeeds_after_failures() -> void:
	var attempts := [0]
	var flaky := func():
		attempts[0] += 1
		if attempts[0] < 3:
			return Promise.reject("fail-%d" % attempts[0])
		return Promise.resolve("ok")
	var r: Array = await Promise.retry(flaky, 5).await_status()
	assert_eq(r[0], Promise.Status.RESOLVED)
	assert_eq(r[1], "ok")
	assert_eq(attempts[0], 3)


func test_retry_rejects_after_exhausting_attempts() -> void:
	var attempts := [0]
	var always_fail := func():
		attempts[0] += 1
		return Promise.reject("fail-%d" % attempts[0])
	var r: Array = await Promise.retry(always_fail, 2).await_status()
	assert_eq(r[0], Promise.Status.REJECTED)
	assert_eq(r[1], "fail-3")  # 1 initial + 2 retries
	assert_eq(attempts[0], 3)


func test_retry_with_delay_waits_between_attempts() -> void:
	var attempts := [0]
	var start := Time.get_ticks_msec()
	var flaky := func():
		attempts[0] += 1
		if attempts[0] < 3:
			return Promise.reject("fail")
		return Promise.resolve("ok")
	var r: Array = await Promise.retry_with_delay(flaky, 5, 0.05).await_status()
	var elapsed_ms := Time.get_ticks_msec() - start
	assert_eq(r[1], "ok")
	assert_eq(attempts[0], 3)
	assert_gt(elapsed_ms, 80, "two 50ms delays should have elapsed")


func test_delay_resolves_with_seconds_value() -> void:
	var start := Time.get_ticks_msec()
	var r: Array = await Promise.delay(0.1).await_status()
	var elapsed_ms := Time.get_ticks_msec() - start
	assert_eq(r[0], Promise.Status.RESOLVED)
	assert_eq(r[1], 0.1)
	assert_gt(elapsed_ms, 80)


# ---------------------------------------------------------------------------
# from_signal
# ---------------------------------------------------------------------------

func test_from_signal_resolves_on_emission() -> void:
	var e := Emitter.new()
	var p := Promise.from_signal(e.fired)
	e.fired.emit("hello")
	await wait_process_frames(3)  # connection is CONNECT_DEFERRED (flushed on process frames)
	assert_eq(p.get_status(), Promise.Status.RESOLVED)
	var r: Array = await p.await_status()
	assert_eq(r[1], "hello")


func test_from_signal_with_predicate_waits_for_match() -> void:
	var e := Emitter.new()
	var at_least_five := func(v): return v >= 5
	var p := Promise.from_signal(e.fired, at_least_five)
	e.fired.emit(1)
	await wait_process_frames(3)
	assert_eq(p.get_status(), Promise.Status.PENDING)
	e.fired.emit(7)
	await wait_process_frames(3)
	assert_eq(p.get_status(), Promise.Status.RESOLVED)
	var r: Array = await p.await_status()
	assert_eq(r[1], 7)


func test_from_signal_disconnects_after_resolving() -> void:
	var e := Emitter.new()
	var p := Promise.from_signal(e.fired)
	e.fired.emit("once")
	await wait_process_frames(3)
	assert_eq(e.fired.get_connections().size(), 0)
	assert_eq(p.get_status(), Promise.Status.RESOLVED)


func test_from_signal_cancel_disconnects() -> void:
	var e := Emitter.new()
	var p := Promise.from_signal(e.fired)
	assert_eq(e.fired.get_connections().size(), 1)
	p.cancel()
	assert_eq(e.fired.get_connections().size(), 0)
	assert_eq(p.get_status(), Promise.Status.CANCELLED)
	# A late emission must not resurrect it.
	e.fired.emit("ghost")
	await wait_process_frames(3)
	assert_eq(p.get_status(), Promise.Status.CANCELLED)


# ---------------------------------------------------------------------------
# get_status sanity
# ---------------------------------------------------------------------------

func test_get_status_transitions() -> void:
	var d := _deferred()
	assert_eq(d.promise.get_status(), Promise.Status.PENDING)
	d.resolve.call(1)
	assert_eq(d.promise.get_status(), Promise.Status.RESOLVED)

	var d2 := _deferred()
	d2.promise.catch(func(_r): pass)  # mark handled
	d2.reject.call("e")
	assert_eq(d2.promise.get_status(), Promise.Status.REJECTED)


# ---------------------------------------------------------------------------
# PromiseError
# ---------------------------------------------------------------------------

func test_promise_error_defaults() -> void:
	var err := PromiseError.new("oops")
	assert_eq(err.message, "oops")
	assert_eq(err.kind, PromiseError.Kind.EXECUTION_ERROR)
	assert_eq(err.context, "")
	assert_null(err.parent)


func test_promise_error_is_kind() -> void:
	var err := PromiseError.new("msg", PromiseError.Kind.TIMED_OUT)
	assert_true(PromiseError.is_kind(err, PromiseError.Kind.TIMED_OUT))
	assert_false(PromiseError.is_kind(err, PromiseError.Kind.EXECUTION_ERROR))
	assert_false(PromiseError.is_kind("not an error", PromiseError.Kind.TIMED_OUT))
	assert_false(PromiseError.is_kind(null, PromiseError.Kind.TIMED_OUT))


func test_promise_error_extend_links_cause_chain() -> void:
	var root := PromiseError.new("root cause", PromiseError.Kind.TIMED_OUT)
	var child := root.extend("wrapper", "in test")
	assert_eq(child.parent, root)
	assert_eq(child.kind, root.kind, "extend preserves the kind")
	var s := str(child)
	assert_string_contains(s, "TIMED_OUT")
	assert_string_contains(s, "wrapper")
	assert_string_contains(s, "in test")
	assert_string_contains(s, "root cause")


func test_promise_error_to_string_without_context() -> void:
	var err := PromiseError.new("plain")
	var s := str(err)
	assert_string_contains(s, "EXECUTION_ERROR")
	assert_string_contains(s, "plain")