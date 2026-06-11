<p align="center">
  <img src="logo.png" alt="gd-promise logo" width="256">
</p>

<h1 align="center">gd-promise</h1>

<p align="center">
  A Promise/A+ inspired promise library for Godot 4 GDScript,<br>
faithfully ported from
  <a href="https://github.com/evaera/roblox-lua-promise">evaera's roblox-lua-promise</a>.
</p>

## Who is this for?
- Those wanting a cleaner way to manage asynchronous blocks
- Roblox developers used to the Promise library

## Why use promises?

While GDScript already has the `await` keyword `await` alone composes poorly. There is no
built-in way to race two operations, retry a flaky one, run a list serially,
bound a wait with a timeout, or cancel work that nobody needs anymore. And
because any function containing an `await` silently becomes a coroutine,
awaiting deep in a call stack "contaminates" every caller above it.

gd-promise gives you both styles and lets them mix freely:

- **Callback style**: `and_then` / `catch` / `finally_cb` in plain
  synchronous functions. No coroutines, returns immediately, ideal for signal
  handlers and UI code.
- **Coroutine style**: `await p.await_status()` for linear, top-to-bottom
  flows like loading sequences.

Plus the things bare `await` can't do: combinators (`all`, `any`, `some`,
`race`, `all_settled`), serial iteration (`each`, `fold`), `retry`,
`timeout`, easy signal bridging (`from_signal`), and a real cancellation model.

## Requirements

- **Godot 4.3+** (Godot 3 support being explored)

## Installation

Copy `addons/gd-promise/` into your project's `addons/` folder.

To verify your install, run `promise_example.tscn` or `promise_interactive_example.tscn`

## Quick start

```gdscript
# Create — the executor runs immediately (promises are eager):
var p := Promise.new_promise(func(resolve, reject, on_cancel):
	on_cancel.call(func(): http.cancel_request())
	http.request_completed.connect(func(_r, code, _h, body):
		if code == 200: resolve.call(body)
		else: reject.call("HTTP %d" % code)
	, CONNECT_ONE_SHOT)
	http.request(url)
)

# Consume with callbacks (plain synchronous function — no await):
p.and_then(func(body): print("got ", body.size(), " bytes")) \
	.catch(func(err): push_warning(err))

# ...or by suspending (this function becomes a coroutine):
var result: Array = await p.await_status()   # [Status, value]
if result[0] == Promise.Status.RESOLVED:
	print(result[1])
```

The executor may declare fewer parameters — `func(resolve)` is fine; extras
are simply not passed. The same applies to handlers: `and_then(func(): ...)`
works when you don't need the value.

## API overview

### Static constructors

| Function | Description |
| --- | --- |
| `Promise.new_promise(executor)` | Run `executor(resolve, reject, on_cancel)` immediately. |
| `Promise.resolve(value)` | Already-resolved promise. A Promise value is adopted (chained onto). |
| `Promise.reject(reason)` | Already-rejected promise. Must be consumed, or it warns next frame. |
| `Promise.defer(executor)` | Like `new_promise`, but the executor runs next process frame. |
| `Promise.try_call(callback, args)` | Call now; wrap the return value (Promise returns are adopted). |
| `Promise.promisify(callback)` | Returns a `func(args) -> Promise` wrapper. |
| `Promise.delay(seconds)` | Resolves with `seconds` after the time passes. |
| `Promise.from_signal(sig, predicate?)` | Resolves on the next emission (passing the predicate). |

### Combinators

| Function | Resolves with | Rejects when | Cancels losers? |
| --- | --- | --- | --- |
| `all(promises)` | every value, input order | any input rejects | yes |
| `some(promises, n)` | first `n` values, arrival order | `n` becomes impossible | yes |
| `any(promises)` | first value | all inputs reject | yes |
| `race(promises)` | first settler's value | first settler rejected | yes |
| `all_settled(promises)` | array of `Status` | never | no |
| `each(list, predicate)` | predicate results, serially | predicate/input rejects | active only |
| `fold(list, reducer, initial)` | accumulated value | reducer/input rejects | no |
| `retry(cb, times, args)` / `retry_with_delay(cb, times, secs, args)` | first success | all attempts fail | — |

*"Cancels losers"*: when the combinator settles, remaining pending
inputs are cancelled **if they have no other consumers** (see Cancellation).

### Instance methods

| Method | Description |
| --- | --- |
| `and_then(on_success, on_failure?)` | Chain. Handlers may return values or Promises (adopted). Registers a consumer. |
| `catch(on_failure)` | `and_then(Callable(), on_failure)`. The handler's return *recovers* the chain. |
| `tap(handler)` | Side effect; original value passes through (waits if handler returns a Promise). |
| `and_then_call(cb, args)` / `and_then_return(value)` | Discard the value; call / substitute. |
| `finally_cb(handler)` | Runs on resolve, reject, **or** cancel. See finally semantics below. |
| `finally_call(cb, args)` / `finally_return(value)` | finally sugar — returns are **discarded** (evaera parity). |
| `timeout(seconds, reason?)` | Reject with `TIMED_OUT` if not resolved in time. **Cancels the source** (see below). |
| `now(reason?)` | Chain if already resolved, else reject with `NOT_RESOLVED_IN_TIME`. |
| `cancel()` | Cancel if pending. Propagates both directions. |
| `get_status()` | `PENDING / RESOLVED / REJECTED / CANCELLED`. |

### Await helpers (require `await`)

| Method | Returns |
| --- | --- |
| `await p.await_status()` | `[Status, value]` — distinguishes rejection from cancellation. |
| `await p.await_result()` | `[resolved: bool, value]`. |
| `await p.await_resolved()` | `bool`. |
| `await p.expect()` | The value; calls `push_error` on rejection/cancellation. Fire-and-forget capable. |

## Cancellation

Cancellation is the library's most distinctive feature (ported from roblox-lua-promise).
The rules:

1. **Downward:** cancelling a promise cancels every pending promise chained
   from it.
2. **Upward:** a promise is cancelled when its **last** consumer is
   cancelled. Chain `and_then` twice and cancel one child — the parent and
   the other child survive.
3. **Hooks:** register cleanup with the executor's `on_cancel` argument; it
   runs when (and only when) the promise is cancelled.
4. **Adoption:** resolving a promise *with* another promise wires
   cancellation through to the adopted promise.
5. **Combinators:** `all` / `some` / `any` / `race` cancel remaining inputs on
   settle — but rule 2 protects any input that something else still consumes.
6. **`timeout` cancels its source** when the timeout fires (it is sugar for a
   `race`), again subject to rule 2.

```gdscript
var download := start_download(url)        # has an on_cancel hook
var ui := download.and_then(show_preview)
ui.cancel()                                # download is cancelled too (rule 2)
```

### ⚠️ Keep in mind: awaiting is not consuming

Only `and_then` / `catch` / `tap` register consumers. **A bare `await` does
not.** A promise you also passed to `race()`, `all()`, or `timeout()` can
therefore be cancelled out from under your `await`:

```gdscript
var save := save_game()
Promise.race([save, user_skipped])   # skip wins...
var ok = await save.await_resolved() # ...save was CANCELLED: ok == false
```

The fix is a keep-alive consumer (or attaching your real downstream work
*before* handing the promise to the combinator):

```gdscript
var save := save_game()
var keep := save.and_then(func(v): return v)   # registers a consumer
Promise.race([save, user_skipped])
var ok = await keep.await_resolved()           # save survives the race
```

This is demonstrated live in `example.gd`, section 12.

## Finally

`finally_cb(handler)` runs the handler — which receives the `Status` — on
resolve, reject, *or* cancel. The returned promise then:

- resolves with the **same value** the parent resolved with,
- rejects with the **same reason** the parent rejected with,
- is cancelled if the parent was cancelled.

The handler's return value is **discarded** — unless it is a Promise, in
which case finally waits for it (still discarding its value), and a
*rejection* from it replaces the outcome. Consequences worth knowing:

- A rejecting chain still rejects **after** a finally — end chains with
  `catch()` (or an `await`) or you'll get the unhandled-rejection warning.
- `finally_return(value)` cannot inject a value into the chain (the handler
  return is discarded). It exists for evaera API parity; use
  `and_then_return` to substitute values.
- finally does **not** count as a consumer: it never keeps a parent alive
  against cancellation, though cancellation still propagates through it in
  both directions.

## Error handling

There is no try/catch in GDScript, so rejections are explicit values, never
thrown. Internal rejections (timeout, `now()`, cancelled `each` inputs,
self-resolution) use `PromiseError`:

```gdscript
p.catch(func(err):
	if PromiseError.is_kind(err, PromiseError.Kind.TIMED_OUT):
		retry_later()
	else:
		push_warning(str(err))   # never assume a rejection is a String
)
```

`PromiseError` carries `message`, `kind`, `context`, and a `parent` cause
chain (`err.extend("while loading save slot 3")`).

A rejection that no `catch` / failure handler / `await` ever observes prints
**`Unhandled Promise rejection`** via `push_warning` on the next frame —
treat those as bugs.

## Known limitations

- **Executor errors are not caught.** Without try/catch, a script error
  inside an executor or handler is a real error and leaves the promise
  permanently PENDING — unless `assert` is used, which always halts execution. Use `assert` to manually trigger errors.
- **`from_signal` supports at most one signal argument.** Emitting a 2+
  argument signal into it is a script error. Pack values into a Dictionary,
  or use a wrapper signal.
- **Freed emitters strand `from_signal` promises** (forever PENDING), and
  cancelling after the emitter is freed touches a dead signal. Pair
  `from_signal` with `.timeout()` as a safety net.
- **Never-settling chains hold references.** A pending parent and child
  reference each other until one settles or cancels (the links are severed on
  settle). Settle or cancel your promises.
- **Settlement dispatch is synchronous.** When a promise settles, attached
  callbacks run *before* the settling call returns (there is no microtask
  queue). By the time any observer sees a settled promise, all of its side
  effects — including propagated cancellations — have already been applied.

## Testing

The addon ships with a GUT test suite (`test/unit/`): **133 tests / 288
assertions** covering API behaviors, the complete cancellation model,
reentrancy, multi-awaiter wakeup, and large-list stress. Four tests are
intentionally left `pending` — they document behaviors GUT cannot assert on
(`push_error` / `push_warning` paths) and the two `from_signal` hazards outlined
above.

Run them with [GUT 9](https://github.com/bitwes/Gut) pointed at
`res://addons/gd-promise/test/unit/`.

## Alternatives
[GodotPromise](https://github.com/SoulsTogetherX/GodotPromise) by SoulsTogetherX

[godot-promise](https://github.com/TheWalruzz/godot-promise) by TheWalruzz

## AI Disclosure
Yes, some artificial intelligence was used in the creation of this addon. An LLM was used to generate:
- Gut tests
- Example scripts
- Documentation and README


**The complete Promise class was designed and implemented by humans**

## Credits

Design ported from
[evaera/roblox-lua-promise](https://github.com/evaera/roblox-lua-promise), adapted to
GDScript's single-value Callables, signals, and (lack of) exception handling.

Javascript Promises A+ [https://github.com/promises-aplus](https://github.com/promises-aplus)

See [LICENSE](LICENSE).