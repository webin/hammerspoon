--- === hs.application ===
---
--- Manipulate running applications

local uielement = hs.uielement  -- Make sure parent module loads
local application = require "hs.application.internal"
application.watcher = require "hs.application.watcher"
local window = require "hs.window"

local type,pairs,ipairs=type,pairs,ipairs
local tunpack,tpack,tsort=table.unpack,table.pack,table.sort

--- hs.application:visibleWindows() -> win[]
--- Method
--- Returns only the app's windows that are visible.
---
--- Parameters:
---  * None
---
--- Returns:
---  * A table containing zero or more hs.window objects
function application:visibleWindows()
  --  return moses.filter(self:allWindows(), window.isVisible)
  local r={}
  if self:isHidden() then return r -- do not check :isHidden for every window
  else for _,w in ipairs(self:allWindows()) do if not w:isMinimized() then r[#r+1]=w end end end
  return r
end

--- hs.application:activate([allWindows]) -> bool
--- Method
--- Tries to activate the app (make its key window focused) and returns whether it succeeded; if allWindows is true, all windows of the application are brought forward as well.
---
--- Parameters:
---  * allWindows - If true, all windows of the application will be brought to the front. Otherwise, only the application's key window will. Defaults to false.
---
--- Returns:
---  * A boolean value indicating whether or not the application could be activated
function application:activate(allWindows)
  allWindows=allWindows and true or false
  if self:isUnresponsive() then return false end
  local win = self:_focusedwindow()
  if win then
    return win:becomeMain() and self:_bringtofront(allWindows)
  else
    return self:_activate(allWindows)
  end
end

--- hs.application:name()
--- Method
--- Alias for `hs.application:title()`
application.name=application.title

--- hs.application.get(hint) -> hs.application object
--- Constructor
--- Gets a running application
---
--- Parameters:
---  * hint - search criterion for the desired application; it can be:
---    - a pid number as per `hs.application:pid()`
---    - a bundle ID string as per `hs.application:bundleID()`
---    - an application name string as per `hs.application:name()`
---
--- Returns:
---  * an hs.application object for a running application that matches the supplied search criterion, or `nil` if not found
---
--- Notes:
---  * see also `hs.application.find`
function application.get(hint)
  return tpack(application.find(hint,true),nil)[1] -- just to be sure, discard extra results
end

--- hs.application.find(hint) -> hs.application object(s)
--- Constructor
--- Finds running applications
---
--- Parameters:
---  * hint - search criterion for the desired application(s); it can be:
---    - a pid number as per `hs.application:pid()`
---    - a bundle ID string as per `hs.application:bundleID()`
---    - a string pattern that matches (via `string.find`) the application name as per `hs.application:name()` (for convenience, the matching will be done on lowercased strings)
---    - a string pattern that matches (via `string.find`) the application's window title per `hs.window:title()` (for convenience, the matching will be done on lowercased strings)
---
--- Returns:
---  * one or more hs.application objects for running applications that match the supplied search criterion, or `nil` if none found
---
--- Notes:
---  * for convenience you can call this as `hs.application(hint)`
---  * use this function when you don't know the exact name of an application you're interested in, i.e.
---    from the console: `hs.application'term' --> hs.application: iTerm2 (0x61000025fb88)  hs.application: Terminal (0x618000447588)`.
---    But be careful when using it in your `init.lua`: `terminal=hs.application'term'` will assign either "Terminal" or "iTerm2" arbitrarily (or even,
---    if neither are running, any other app with a window that happens to have "term" in its title); to make sure you get the right app in your scripts,
---    use `hs.application.get` with the exact name: `terminal=hs.application.get'Terminal' --> "Terminal" app, or nil if it's not running`
---
--- Usage:
--- -- by pid
--- hs.application(42):name() --> Finder
--- -- by bundle id
--- hs.application'com.apple.Safari':name() --> Safari
--- -- by name
--- hs.application'chrome':name() --> Google Chrome
--- -- by window title
--- hs.application'bash':name() --> Terminal
function application.find(hint,exact)
  if hint==nil then return end
  local typ=type(hint)
  if typ=='number' then return application.applicationForPID(hint)
  elseif typ~='string' then error('hint must be a number or string',2) end
  local r=application.applicationsForBundleID(hint)
  if #r>0 then return tunpack(r) end
  local apps=application.runningApplications()

  if exact then for _,a in ipairs(apps) do if a:name()==hint then r[#r+1]=a end end
  else for _,a in ipairs(apps) do if a:name():lower():find(hint:lower()) then r[#r+1]=a end end end
  tsort(r,function(a,b)return a:kind()>b:kind()end) -- gui apps first
  if exact or #r>0 then return tunpack(r) end

  r=tpack(window.find(hint))
  local rs={} for _,w in ipairs(r) do rs[w:application()]=true end -- :toSet
  for a in pairs(rs) do r[#r+1]=a end -- and back, no dupes
  if #r>0 then return tunpack(r) end
end

--- hs.application:findWindow(titlePattern) -> hs.window object(s)
--- Method
--- Finds windows from this application
---
--- Parameters:
---  * titlePattern - a string pattern that matches (via `string.find`) the window title(s) as per `hs.window:title()` (for convenience, the matching will be done on lowercased strings)
---
--- Returns:
---  * one or more hs.window objects belonging to this application that match the supplied search criterion, or `nil` if none found

function application:findWindow(hint)
  return window.find(hint,false,self:allWindows())
end

--- hs.application:getWindow(title) -> hs.window object
--- Method
--- Gets a specific window from this application
---
--- Parameters:
---  * title - the desired window's title string as per `hs.window:title()`
---
--- Returns:
---  * the desired hs.window object belonging to this application, or `nil` if not found
function application:getWindow(hint)
  return tpack(window.find(hint,true,self:allWindows()),nil)[1]
end

--- hs.application.open(app) -> hs.application object
--- Constructor
--- Launches an application, or activates it if it's already running
---
--- Parameters:
---  * app - a string describing the application to open; it can be:
---    - the application's name as per `hs.application:name()`
---    - the full path to an application on disk (including the `.app` suffix)
---    - the application's bundle ID as per `hs.application:bundleID()`
---
--- Returns:
---  * the `hs.application` object for the launched or activated application; `nil` if not found
function application.open(app)
  if type(app)~='string' then error('app must be a string',2) end
  if application.launchOrFocus(app) then return application.find(app,true) end
  if application.launchOrFocusByBundleID(app) then return application.find(app,true) end
end

do
  local mt=getmetatable(application)
  if not mt.__call then mt.__call=function(t,...)if t.find then return t.find(...) else error('cannot call uielement',2) end end end
end
--getmetatable(application).__call=function(_,...)return application.find(...)end
return application

