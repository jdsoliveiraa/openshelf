-- Flow 2: hold-to-download from the results list, My books, See all, settings toggles.
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local App = require("app")
local OUT = os.getenv("OPENSHELF_SHOT_DIR")
local step = 0
local function log(...) print("DEVSCRIPT", ...) end
local function shot(name) step = step + 1; local p = string.format("%s/%02d-%s.png", OUT, step, name); log("shot", p, pcall(function() return Screen:shot(p) end)) end
local function at(t, fn, label) UIManager:scheduleIn(t, function() local ok, err = pcall(fn); log(label or "", ok and "ok" or ("ERR " .. tostring(err))) end) end
local function top() return App.views[#App.views] end
local function home() return App.homeView() end

at(2,  function() home():startSearch("jane austen") end, "search")
at(14, function() shot("results") end)
at(15, function() local e = home().entries[2]; log("hold", e and e.title); App.holdDownload(e, home()) end, "hold")
at(17, function() shot("row-downloading") end)
at(30, function() shot("row-done") end)
at(31, function() home():goPage(2) end, "page2")
at(33, function() shot("results-p2") end)
at(34, function() home():goHome() end, "home")
at(37, function() shot("home-mybooks") end)
at(38, function() home():openMyBooks() end, "mybooks")
at(41, function() shot("mybooks") end)
at(42, function() local mb = top(); local b = mb:buckets(); mb:openList("Not started", b.new) end, "see all")
at(45, function() shot("mybooks-list") end)
at(46, function() top():toggleView() end, "grid")
at(48, function() shot("mybooks-grid") end)
at(49, function() local e = top().entries[1]; top():openDetail(e) end, "detail downloaded")
at(52, function() shot("detail-downloaded") end)
at(53, function() UIManager:close(top()); UIManager:close(top()); UIManager:close(top()) end, "back to home")
at(55, function() shot("home-final") end)
at(56, function() log("done"); os.exit(0) end, "exit")
