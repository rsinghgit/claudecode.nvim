-- luacheck: globals expect
require("tests.busted_setup")

describe("Diff Auto-Close on Accept Feature", function()
   local diff
   local config
   local original_vim_functions = {}
   local deferred_functions = {} -- Track functions scheduled with vim.defer_fn
   local close_diff_calls = {} -- Track calls to close_diff_by_tab_name

   local function setup()
      package.loaded["claudecode.diff"] = nil
      package.loaded["claudecode.config"] = nil

      assert(_G.vim, "Global vim mock not initialised by busted_setup.lua")
      assert(_G.vim.fn, "Global vim.fn mock not initialised")

      -- Mock vim.defer_fn to capture scheduled functions
      original_vim_functions["defer_fn"] = _G.vim.defer_fn
      local deferred_fn_override = function(fn, delay)
         table.insert(deferred_functions, { fn = fn, delay = delay })
      end
      _G.vim.defer_fn = deferred_fn_override

      -- Mock nvim_buf_get_option to return true (modified check) by default
      original_vim_functions["nvim_buf_get_option"] = _G.vim.api.nvim_buf_get_option
      local buf_get_option_override = function()
         return true
      end
      _G.vim.api.nvim_buf_get_option = buf_get_option_override

      -- Load modules
      config = require("claudecode.config")
      diff = require("claudecode.diff")

      -- Initialize diff with default config
      diff.setup(config.defaults)

      -- Mock close_diff_by_tab_name to track calls
      diff._original_close_diff = diff.close_diff_by_tab_name
      diff.close_diff_by_tab_name = function(tab_name)
         table.insert(close_diff_calls, tab_name)
      end
   end

   local function teardown()
      -- Restore original functions
      if original_vim_functions["defer_fn"] then
         _G.vim.defer_fn = original_vim_functions["defer_fn"]
         original_vim_functions["defer_fn"] = nil
      end

      if original_vim_functions["nvim_buf_get_option"] then
         _G.vim.api.nvim_buf_get_option = original_vim_functions["nvim_buf_get_option"]
         original_vim_functions["nvim_buf_get_option"] = nil
      end

      if diff and diff._original_close_diff then
         diff.close_diff_by_tab_name = diff._original_close_diff
         diff._original_close_diff = nil
      end

      -- Clear tracking tables
      deferred_functions = {}
      close_diff_calls = {}
   end

   before_each(function()
      setup()
   end)

   after_each(function()
      teardown()
   end)

   describe("Configuration", function()
      it("should respect auto_close_on_accept config option when true", function()
         -- This is tested through behavior - see "Auto-close Behaviour" tests
         -- The config is stored internally in diff module
         local test_config = config.apply({
            diff_opts = {
               auto_close_on_accept = true,
            },
         })

         expect(test_config.diff_opts).to_be_table()
         expect(test_config.diff_opts.auto_close_on_accept).to_be(true)
      end)

      it("should default auto_close_on_accept to false", function()
         local test_config = config.apply({})

         expect(test_config.diff_opts.auto_close_on_accept).to_be(false)
      end)

      it("should accept false value for auto_close_on_accept", function()
         local test_config = config.apply({
            diff_opts = {
               auto_close_on_accept = false,
            },
         })

         expect(test_config.diff_opts.auto_close_on_accept).to_be(false)
      end)
   end)

   describe("Auto-close Behaviour", function()
      it("should schedule cleanup when auto_close_on_accept is enabled", function()
         -- Setup config with auto_close enabled
         diff.setup({
            diff_opts = {
               auto_close_on_accept = true,
            },
         })

         -- Create a mock diff entry
         local tab_name = "test_diff_tab"
         diff._get_active_diffs()[tab_name] = {
            status = "pending",
            resolution_callback = function() end,
            file_visible_in_window = true,
            is_new_file = false,
         }

         local buffer_id = 1
         _G.vim._buffers[buffer_id] = { lines = { "line1", "line2" } }
         deferred_functions = {}

         diff._resolve_diff_as_saved(tab_name, buffer_id)

         -- Verify defer_fn was called
         expect(#deferred_functions).to_be(1)
         expect(deferred_functions[1].delay).to_be(150)

         -- Verify the deferred function would call close_diff_by_tab_name
         close_diff_calls = {}
         deferred_functions[1].fn() -- Execute the deferred function

         expect(#close_diff_calls).to_be(1)
         expect(close_diff_calls[1]).to_be(tab_name)
      end)

      it("should NOT schedule cleanup when auto_close_on_accept is disabled", function()
         -- Setup config with auto_close disabled
         diff.setup({
            diff_opts = {
               auto_close_on_accept = false,
            },
         })

         -- Create a mock diff entry
         local tab_name = "test_diff_tab"
         diff._get_active_diffs()[tab_name] = {
            status = "pending",
            resolution_callback = function() end,
            file_visible_in_window = true,
            is_new_file = false,
         }

         local buffer_id = 1
         _G.vim._buffers[buffer_id] = { lines = { "line1", "line2" } }
         deferred_functions = {}

         diff._resolve_diff_as_saved(tab_name, buffer_id)

         -- Verify defer_fn was NOT called
         expect(#deferred_functions).to_be(0)
      end)

      it("should only close diff if status is still 'saved'", function()
         diff.setup({
            diff_opts = {
               auto_close_on_accept = true,
            },
         })

         local tab_name = "test_diff_tab"
         diff._get_active_diffs()[tab_name] = {
            status = "pending",
            resolution_callback = function() end,
         }

         local buffer_id = 1
         _G.vim._buffers[buffer_id] = { lines = { "line1" } }
         deferred_functions = {}
         diff._resolve_diff_as_saved(tab_name, buffer_id)

         -- Change status before executing deferred function
         diff._get_active_diffs()[tab_name].status = "rejected"

         close_diff_calls = {}
         deferred_functions[1].fn()

         -- Should NOT close because status is not 'saved'
         expect(#close_diff_calls).to_be(0)
      end)

      it("should not close if diff no longer exists", function()
         diff.setup({
            diff_opts = {
               auto_close_on_accept = true,
            },
         })

         local tab_name = "test_diff_tab"
         diff._get_active_diffs()[tab_name] = {
            status = "pending",
            resolution_callback = function() end,
         }

         local buffer_id = 1
         _G.vim._buffers[buffer_id] = { lines = { "line1" } }
         deferred_functions = {}
         diff._resolve_diff_as_saved(tab_name, buffer_id)

         -- Remove diff before executing deferred function
         diff._get_active_diffs()[tab_name] = nil

         close_diff_calls = {}
         deferred_functions[1].fn()

         -- Should NOT close because diff no longer exists
         expect(#close_diff_calls).to_be(0)
      end)
   end)

   describe("file_visible_in_window Tracking", function()
      it("should track when file was already open", function()
         local tab_name = "test_diff"
         diff._get_active_diffs()[tab_name] = {
            status = "pending",
            file_visible_in_window = true,
            target_window = 1,
            is_new_file = false,
         }

         local diff_data = diff._get_active_diffs()[tab_name]
         expect(diff_data.file_visible_in_window).to_be(true)
      end)

      it("should track when file was NOT already open", function()
         local tab_name = "test_diff"
         diff._get_active_diffs()[tab_name] = {
            status = "pending",
            file_visible_in_window = false,
            target_window = 1,
            is_new_file = false,
         }

         local diff_data = diff._get_active_diffs()[tab_name]
         expect(diff_data.file_visible_in_window).to_be(false)
      end)
   end)

   describe("Integration with close_diff_by_tab_name", function()
      it("should pass correct tab_name to close_diff_by_tab_name", function()
         diff.setup({
            diff_opts = {
               auto_close_on_accept = true,
            },
         })

         local tab_name = "specific_diff_identifier"
         diff._get_active_diffs()[tab_name] = {
            status = "pending",
            resolution_callback = function() end,
         }

         local buffer_id = 1
         _G.vim._buffers[buffer_id] = { lines = { "content" } }

         deferred_functions = {}
         close_diff_calls = {}

         diff._resolve_diff_as_saved(tab_name, buffer_id)
         deferred_functions[1].fn()

         expect(close_diff_calls[1]).to_be(tab_name)
      end)

      it("should handle multiple diffs independently", function()
         diff.setup({
            diff_opts = {
               auto_close_on_accept = true,
            },
         })

         -- Create two diffs
         local tab_name_1 = "diff_1"
         local tab_name_2 = "diff_2"

         diff._get_active_diffs()[tab_name_1] = {
            status = "pending",
            resolution_callback = function() end,
         }
         diff._get_active_diffs()[tab_name_2] = {
            status = "pending",
            resolution_callback = function() end,
         }

         _G.vim._buffers[1] = { lines = { "content1" } }
         _G.vim._buffers[2] = { lines = { "content2" } }

         deferred_functions = {}
         close_diff_calls = {}

         -- Resolve first diff
         diff._resolve_diff_as_saved(tab_name_1, 1)
         expect(#deferred_functions).to_be(1)

         -- Resolve second diff
         diff._resolve_diff_as_saved(tab_name_2, 2)
         expect(#deferred_functions).to_be(2)

         -- Execute deferred functions
         deferred_functions[1].fn()
         deferred_functions[2].fn()

         -- Both diffs should be closed
         expect(#close_diff_calls).to_be(2)
         expect(close_diff_calls[1]).to_be(tab_name_1)
         expect(close_diff_calls[2]).to_be(tab_name_2)
      end)
   end)

   describe("Status Transitions", function()
      it("should set status to 'saved' after resolution", function()
         diff.setup({
            diff_opts = {
               auto_close_on_accept = false,
            },
         })

         local tab_name = "test_diff"
         diff._get_active_diffs()[tab_name] = {
            status = "pending",
            resolution_callback = function() end,
         }

         local buffer_id = 1
         _G.vim._buffers[buffer_id] = { lines = { "content" } }

         diff._resolve_diff_as_saved(tab_name, buffer_id)

         expect(diff._get_active_diffs()[tab_name].status).to_be("saved")
      end)

      it("should not process diff if status is not 'pending'", function()
         diff.setup({
            diff_opts = {
               auto_close_on_accept = true,
            },
         })

         local tab_name = "test_diff"
         diff._get_active_diffs()[tab_name] = {
            status = "rejected", -- Not pending
            resolution_callback = function() end,
         }

         local buffer_id = 1
         _G.vim._buffers[buffer_id] = { lines = { "content" } }

         deferred_functions = {}

         diff._resolve_diff_as_saved(tab_name, buffer_id)

         -- Should not schedule any cleanup
         expect(#deferred_functions).to_be(0)
      end)
   end)

   describe("Edge Cases", function()
      it("should handle missing diff_opts gracefully", function()
         diff.setup({}) -- No diff_opts

         local tab_name = "test_diff"
         diff._get_active_diffs()[tab_name] = {
            status = "pending",
            resolution_callback = function() end,
         }

         local buffer_id = 1
         _G.vim._buffers[buffer_id] = { lines = { "content" } }

         deferred_functions = {}

         -- Should not error, just skip auto-close
         diff._resolve_diff_as_saved(tab_name, buffer_id)

         expect(#deferred_functions).to_be(0)
      end)

      it("should handle nil config gracefully", function()
         -- Don't call diff.setup at all - leave config as nil
         package.loaded["claudecode.config"] = nil
         package.loaded["claudecode.diff"] = nil
         config = require("claudecode.config")

         diff = require("claudecode.diff")
         -- Don't call diff.setup() - this leaves internal config as nil
         diff.close_diff_by_tab_name = function(tab_name)
            table.insert(close_diff_calls, tab_name)
         end

         local tab_name = "test_diff"
         diff._get_active_diffs()[tab_name] = {
            status = "pending",
            resolution_callback = function() end,
         }

         local buffer_id = 1
         _G.vim._buffers[buffer_id] = { lines = { "content" } }

         deferred_functions = {}

         -- Should not error
         diff._resolve_diff_as_saved(tab_name, buffer_id)

         expect(#deferred_functions).to_be(0)
      end)

      it("should handle new file correctly", function()
         local tab_name = "test_diff"
         diff._get_active_diffs()[tab_name] = {
            status = "pending",
            file_visible_in_window = false,
            is_new_file = true, -- This is a new file
            target_window = 1,
         }

         local diff_data = diff._get_active_diffs()[tab_name]
         expect(diff_data.is_new_file).to_be(true)
         expect(diff_data.file_visible_in_window).to_be(false)
      end)
   end)
end)
