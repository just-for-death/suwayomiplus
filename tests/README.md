# Suwayomi+ Test Suite

Pure-Lua unit tests for the new features added to **suwayomiplus** and **MaxOutUI**.  
Each test file is self-contained: it runs without the full KOReader runtime by mocking the handful of KOReader-specific modules it needs.

---

## Running the Tests

### Option A — Full suite via test_runner (recommended)

From KOReader's **Terminal** plugin:

```sh
lua /mnt/us/koreader/plugins/suwayomiplus.koplugin/tests/test_runner.lua
```

From a desktop Lua interpreter during development:

```sh
cd /path/to/kindlexmanga
lua suwayomiplus/tests/test_runner.lua
```

`test_runner.lua` loads every test file via `dofile`, prints a per-assertion
log, and exits with code `1` if any assertion failed (useful in CI).

### Option B — Individual test file

Each test file bootstraps its own minimal assertion helpers when it is not
invoked through `test_runner.lua`:

```sh
lua suwayomiplus/tests/test_library_sort.lua
lua suwayomiplus/tests/test_wakeup_guard.lua
lua suwayomiplus/tests/test_unread_count_display.lua
lua suwayomiplus/tests/test_continue_reading.lua
```

### Lua version

The tests are written for **Lua 5.1 / LuaJIT** (the same version KOReader uses).
They will also run on Lua 5.2–5.4 with no changes.

---

## What Each File Covers

| File | Source module | What is tested |
|---|---|---|
| `test_runner.lua` | *(entry point)* | Assertion helpers; runs all suites; prints summary |
| `test_library_sort.lua` | `suwayomi/client/library.lua` | `sortLibraryMangaByUnread` sort order: descending by unread, alphabetical tie-break, nil coercion, non-mutation of input |
| `test_wakeup_guard.lua` | `suwayomi/network/wakeup_guard.lua` | `isWakeup`, `recordSuccess`, `getMaxRetries`, `getReconnectDelay` — with a controllable `os.time` mock and fresh module per scenario |
| `test_unread_count_display.lua` | `suwayomi/ui/list_rows.lua` | `getMangaMandatory`: all combinations of `show_unread_count`, `show_in_library`, `chapter_count`, loading/error states, nil/non-table inputs |
| `test_continue_reading.lua` | `suwayomi/plugin/continue_reading.lua` | History entry selection loop: empty history, all-read, `first_unread_chapter` present, skip-to-second, unread_count-only, nil manga entries, type-guard on string unread_count, break-at-first semantics |

---

## How Tests Are Structured

### Assertion helpers

`test_runner.lua` exposes these globals that every `dofile`'d test file can use:

```lua
assert_eq(a, b, label)        -- strict equality (==)
assert_true(value, label)     -- truthy
assert_false(value, label)    -- falsy
assert_not_nil(value, label)  -- not nil
assert_nil(value, label)      -- is nil
```

Each test file also defines local fallbacks of these helpers so it remains
runnable standalone.

### Test isolation for stateful modules

`test_wakeup_guard.lua` calls `dofile(guard_path)` once per scenario to get a
fresh module instance with `_last_successful_request_time` reset to `0`.
`os.time` is monkey-patched globally before each load and restored after all
tests complete.

---

## Adding New Tests

### Add a test case to an existing file

Open the relevant test file and add a new `do … end` block following the
existing pattern:

```lua
do
    local result = functionUnderTest(someInput)
    assert_eq(result, expectedValue, "description of what is being checked")
end
```

Use a descriptive `label` — it appears in both pass and fail output.

### Add a new test file

1. Create `tests/test_<feature>.lua` using this template:

```lua
-- test_<feature>.lua — Tests for suwayomi/path/to/module.lua

-- Standalone bootstrap (copy from any existing test file)
local _standalone = type(assert_eq) ~= "function"
if _standalone then
    -- paste the bootstrap block here
end

-- Mock any KOReader-specific requires before loading real modules
-- e.g. package.preload["some/module"] = function() return MockModule end

-- Your test cases here
do
    local result = ...
    assert_eq(result, expected, "descriptive label")
end
```

2. Register the new file in `test_runner.lua`:

```lua
run_suite("My Feature Name", "test_<feature>.lua")
```

### Guidelines

- **One `do … end` block per scenario** — keeps failures isolated and easy to read.
- **Mock minimally** — only stub what prevents the file from loading; leave real
  logic intact.
- **Duplicate, don't import** — for local functions (like `sortLibraryMangaByUnread`),
  copy the exact function into the test file and add a comment pointing at the
  source location.  A divergence between the copy and the source is itself a
  useful signal.
- **Test the contract, not the implementation** — assert on observable outputs
  and side-effects, not internal variable values.
