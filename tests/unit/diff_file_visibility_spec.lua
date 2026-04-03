-- luacheck: globals expect
-- Tests for the file_visible_in_window flag in _setup_blocking_diff.
-- Verifies that the flag is only true when the file is actually displayed
-- in a window, NOT when it merely has a loaded (but hidden) buffer.
require("tests.busted_setup")

describe("Diff file_visible_in_window tracking", function()
  local diff

  -- IDs used across helpers
  local OTHER_FILE = "/tmp/claudecode_test_other_file.lua"
  local DIFF_FILE = "/tmp/claudecode_test_diff_file.lua"
  local OTHER_BUF = 10
  local OTHER_WIN = 1000
  local DIFF_BUF = 20
  local TAB_NAME = "test_diff_tab"

  local function create_temp_files()
    local f1 = io.open(OTHER_FILE, "w")
    f1:write("other file content\n")
    f1:close()
    local f2 = io.open(DIFF_FILE, "w")
    f2:write("diff file original content\n")
    f2:close()
  end

  local function remove_temp_files()
    os.remove(OTHER_FILE)
    os.remove(DIFF_FILE)
  end

  local function reset_vim_state()
    -- One tab, one window showing OTHER_FILE
    _G.vim._buffers = {
      [OTHER_BUF] = { name = OTHER_FILE, lines = { "other" }, options = {} },
    }
    _G.vim._windows = {
      [OTHER_WIN] = { buf = OTHER_BUF, width = 80 },
    }
    _G.vim._win_tab = { [OTHER_WIN] = 1 }
    _G.vim._tab_windows = { [1] = { OTHER_WIN } }
    _G.vim._current_window = OTHER_WIN
    _G.vim._current_tabpage = 1
    _G.vim._tabs = { [1] = true }
    _G.vim._next_winid = 2000
  end

  local function setup()
    package.loaded["claudecode.diff"] = nil
    package.loaded["claudecode.config"] = nil
    package.loaded["claudecode.terminal"] = nil
    package.loaded["claudecode.logger"] = nil

    -- Suppress terminal dependency
    package.loaded["claudecode.terminal"] = {
      get_active_terminal_bufnr = function()
        return nil
      end,
      ensure_visible = function() end,
    }

    -- Silence logger
    package.loaded["claudecode.logger"] = {
      debug = function() end,
      info = function() end,
      warn = function() end,
      error = function() end,
    }

    -- Stub missing vim globals used by diff.lua
    _G.vim.b = setmetatable({}, {
      __index = function(_, buf)
        _G.vim._buf_vars = _G.vim._buf_vars or {}
        _G.vim._buf_vars[buf] = _G.vim._buf_vars[buf] or {}
        return _G.vim._buf_vars[buf]
      end,
      __newindex = function(_, buf, val)
        _G.vim._buf_vars = _G.vim._buf_vars or {}
        _G.vim._buf_vars[buf] = val
      end,
    })
    _G.vim.schedule = function(fn)
      fn()
    end
    _G.vim.defer_fn = function() end -- don't auto-close during setup

    -- nvim_get_option_value: return sensible defaults for window options
    _G.vim.api.nvim_get_option_value = function(name, opts)
      local defaults = {
        number = false,
        relativenumber = false,
        signcolumn = "auto",
        statuscolumn = "",
        foldcolumn = "0",
        cursorline = false,
        cursorcolumn = false,
        colorcolumn = "",
        cursorlineopt = "both",
        spell = false,
        list = false,
        wrap = false,
        linebreak = false,
        breakindent = false,
        showbreak = "",
        scrolloff = 0,
        sidescrolloff = 0,
        filetype = "",
        buftype = "",
        modified = false,
      }
      return defaults[name]
    end

    -- nvim_buf_get_option: needed by find_main_editor_window and choose_original_window
    _G.vim.api.nvim_buf_get_option = function(buf, name)
      if _G.vim._buffers[buf] and _G.vim._buffers[buf].options then
        local v = _G.vim._buffers[buf].options[name]
        if v ~= nil then
          return v
        end
      end
      local defaults = { buftype = "", filetype = "", modified = false }
      return defaults[name]
    end

    -- fnamemodify: handle ":e" extension modifier used in diff.lua
    local orig_fnamemodify = _G.vim.fn.fnamemodify
    _G.vim.fn.fnamemodify = function(path, modifier)
      if modifier == ":e" then
        return path:match("%.([^%.]+)$") or ""
      end
      return orig_fnamemodify(path, modifier)
    end

    reset_vim_state()
    create_temp_files()

    diff = require("claudecode.diff")
    diff.setup({ diff_opts = { auto_close_on_accept = true } })
  end

  local function teardown()
    remove_temp_files()
    _G.vim.b = nil
    _G.vim.schedule = nil
    _G.vim.defer_fn = nil
    _G.vim.api.nvim_get_option_value = nil
  end

  before_each(setup)
  after_each(teardown)

  -- Helper: call _setup_blocking_diff and return the registered diff state
  local function run_setup()
    local ok, err = pcall(function()
      diff._setup_blocking_diff({
        old_file_path = DIFF_FILE,
        new_file_path = DIFF_FILE,
        new_file_contents = "new content\n",
        tab_name = TAB_NAME,
      }, function() end)
    end)
    return ok, err, diff._get_active_diffs()[TAB_NAME]
  end

  describe("when file is NOT loaded in any buffer", function()
    it("sets file_visible_in_window to false", function()
      -- DIFF_FILE has no buffer at all
      local ok, err, state = run_setup()
      assert.is_true(ok, "setup should not error: " .. tostring(err))
      assert.not_nil(state, "diff state should be registered")
      expect(state.file_visible_in_window).to_be(false)
    end)

    it("creates two new windows for the diff", function()
      local wins_before = vim.api.nvim_list_wins()
      local ok, err = pcall(function()
        diff._setup_blocking_diff({
          old_file_path = DIFF_FILE,
          new_file_path = DIFF_FILE,
          new_file_contents = "new content\n",
          tab_name = TAB_NAME,
        }, function() end)
      end)
      assert.is_true(ok, tostring(err))
      local wins_after = vim.api.nvim_list_wins()
      -- Two additional windows should have been opened (original + proposed)
      assert.is_true(#wins_after >= #wins_before + 2, "expected at least 2 new windows")
    end)
  end)

  describe("when file is loaded in a buffer but NOT in any window", function()
    before_each(function()
      -- Add DIFF_FILE as a loaded hidden buffer (not shown in any window)
      _G.vim._buffers[DIFF_BUF] = { name = DIFF_FILE, lines = { "original" }, options = {} }
      -- No window shows DIFF_BUF
    end)

    it("sets file_visible_in_window to false", function()
      local ok, err, state = run_setup()
      assert.is_true(ok, "setup should not error: " .. tostring(err))
      assert.not_nil(state, "diff state should be registered")
      -- The file has a buffer but no window — should still be false
      expect(state.file_visible_in_window).to_be(false)
    end)

    it("creates two new windows (both should close on cleanup)", function()
      local wins_before = vim.api.nvim_list_wins()
      local ok, err = pcall(function()
        diff._setup_blocking_diff({
          old_file_path = DIFF_FILE,
          new_file_path = DIFF_FILE,
          new_file_contents = "new content\n",
          tab_name = TAB_NAME,
        }, function() end)
      end)
      assert.is_true(ok, tostring(err))
      local wins_after = vim.api.nvim_list_wins()
      assert.is_true(#wins_after >= #wins_before + 2, "expected at least 2 new windows")

      -- Now close and verify both new windows are gone
      diff.close_diff_by_tab_name(TAB_NAME)
      local wins_closed = vim.api.nvim_list_wins()
      assert.are.equal(#wins_before, #wins_closed, "both diff windows should be closed")
    end)
  end)

  describe("when file IS visible in a window", function()
    local DIFF_WIN = 1001

    before_each(function()
      -- Add DIFF_FILE as a loaded buffer displayed in its own window
      _G.vim._buffers[DIFF_BUF] = { name = DIFF_FILE, lines = { "original" }, options = {} }
      _G.vim._windows[DIFF_WIN] = { buf = DIFF_BUF, width = 80 }
      _G.vim._win_tab[DIFF_WIN] = 1
      table.insert(_G.vim._tab_windows[1], DIFF_WIN)
    end)

    it("sets file_visible_in_window to true", function()
      local ok, err, state = run_setup()
      assert.is_true(ok, "setup should not error: " .. tostring(err))
      assert.not_nil(state, "diff state should be registered")
      expect(state.file_visible_in_window).to_be(true)
    end)

    it("does NOT close the original window on cleanup", function()
      local ok = pcall(function()
        diff._setup_blocking_diff({
          old_file_path = DIFF_FILE,
          new_file_path = DIFF_FILE,
          new_file_contents = "new content\n",
          tab_name = TAB_NAME,
        }, function() end)
      end)
      assert.is_true(ok)

      diff.close_diff_by_tab_name(TAB_NAME)

      -- The pre-existing DIFF_WIN should still be open
      assert.is_true(
        vim.api.nvim_win_is_valid(DIFF_WIN),
        "original window should remain open after cleanup"
      )
    end)
  end)
end)