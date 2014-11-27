#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <lauxlib.h>

#define USERDATA_TAG "hs.menubar"

void parse_table(lua_State *L, int idx, NSMenu *menu);
void erase_menu_items(lua_State *L, NSMenu *menu);

@interface clickDelegate : NSObject
@property lua_State *L;
@property int fn;
@end

@implementation clickDelegate
- (void) click:(id __unused)sender {
    lua_State *L = self.L;
    lua_getglobal(L, "debug"); lua_getfield(L, -1, "traceback"); lua_remove(L, -2);
    lua_rawgeti(L, LUA_REGISTRYINDEX, self.fn);
    if (lua_pcall(L, 0, 0, -2) != 0) {
        NSLog(@"%s", lua_tostring(L, -1));
        lua_getglobal(L, "hs"); lua_getfield(L, -1, "showError"); lua_remove(L, -2);
        lua_pushvalue(L, -2);
        lua_pcall(L, 1, 0, 0);
    }
}
@end

@interface menuDelegate : NSObject <NSMenuDelegate>
@property lua_State *L;
@property int fn;
@end

@implementation menuDelegate
- (void) menuNeedsUpdate:(NSMenu *)menu {
    lua_State *L = self.L;
    lua_getglobal(L, "debug"); lua_getfield(L, -1, "traceback"); lua_remove(L, -2);
    lua_rawgeti(L, LUA_REGISTRYINDEX, self.fn);
    if (lua_pcall(L, 0, 1, 0) != LUA_OK) {
        NSLog(@"%s", lua_tostring(L, -1));
        lua_getglobal(L, "hs"); lua_getfield(L, -1, "showError"); lua_remove(L, -2);
        lua_pushvalue(L, -2);
        lua_pcall(L, 1, 0, 0);
        return;
    }
    luaL_checktype(L, lua_gettop(L), LUA_TTABLE);
    erase_menu_items(L, menu);
    parse_table(L, lua_gettop(L), menu);
}
@end

typedef struct _menubaritem_t {
    void *menuBarItemObject;
    void *click_callback;
    int click_fn;
} menubaritem_t;

NSMutableArray *dynamicMenuDelegates;

/// hs.menubar.new() -> menubaritem
/// Constructor
/// Creates a new menu bar item object, which can be added to the system menubar by calling menubaritem:add()
///
/// Note: You likely want to call either hs.menubar:setTitle() or hs.menubar:setIcon() after creating a menubar item, otherwise it will be invisible.
static int menubar_new(lua_State *L) {
    NSStatusBar *statusBar = [NSStatusBar systemStatusBar];
    NSStatusItem *statusItem = [statusBar statusItemWithLength:NSVariableStatusItemLength];

    if (statusItem) {
        menubaritem_t *menuBarItem = lua_newuserdata(L, sizeof(menubaritem_t));
        memset(menuBarItem, 0, sizeof(menubaritem_t));
        menuBarItem->menuBarItemObject = (__bridge_retained void*)statusItem;
        menuBarItem->click_callback = nil;
        menuBarItem->click_fn = 0;
        luaL_getmetatable(L, USERDATA_TAG);
        lua_setmetatable(L, -2);
    } else {
        lua_pushnil(L);
    }

    return 1;
}

/// hs.menubar:setTitle(title)
/// Method
/// Sets the text on a menubar item. If an icon is also set, this text will be displayed next to the icon
static int menubar_settitle(lua_State *L) {
    menubaritem_t *menuBarItem = luaL_checkudata(L, 1, USERDATA_TAG);
    NSString *titleText = [NSString stringWithUTF8String:luaL_checkstring(L, 2)];
    lua_settop(L, 1);
    [(__bridge NSStatusItem*)menuBarItem->menuBarItemObject setTitle:titleText];

    return 0;
}

/// hs.menubar:setIcon(iconfilepath) -> bool
/// Method
/// Loads the image specified by iconfilepath and sets it as the menu bar item's icon
// FIXME: Talk about icon requirements, wrt size/colour and general suitability for retina and yosemite dark mode
static int menubar_seticon(lua_State *L) {
    menubaritem_t *menuBarItem = luaL_checkudata(L, 1, USERDATA_TAG);
    NSImage *iconImage = [[NSImage alloc] initWithContentsOfFile:[NSString stringWithUTF8String:luaL_checkstring(L, 2)]];
    lua_settop(L, 1);
    if (!iconImage) {
        lua_pushnil(L);
        return 1;
    }
    [iconImage setTemplate:YES];
    [(__bridge NSStatusItem*)menuBarItem->menuBarItemObject setImage:iconImage];

    lua_pushboolean(L, 1);
    return 1;
}

/// hs.menubar:setTooltip(tooltip)
/// Method
/// Sets the tooltip text on a menubar item.
static int menubar_settooltip(lua_State *L) {
    menubaritem_t *menuBarItem = luaL_checkudata(L, 1, USERDATA_TAG);
    NSString *toolTipText = [NSString stringWithUTF8String:luaL_checkstring(L, 2)];
    lua_settop(L, 1);
    [(__bridge NSStatusItem*)menuBarItem->menuBarItemObject setToolTip:toolTipText];

    return 0;
}

/// hs.menubar:clickCallback(fn)
/// Method
/// Registers a function to be called when the menubar icon is clicked. If the argument is nil, the previously registered callback is removed.
/// Note: If a menu has been attached to the menubar item, this callback will never be called
static int menubar_click_callback(lua_State *L) {
    menubaritem_t *menuBarItem = luaL_checkudata(L, 1, USERDATA_TAG);
    NSStatusItem *statusItem = (__bridge NSStatusItem*)menuBarItem->menuBarItemObject;
    if (lua_isnil(L, 2)) {
        if (menuBarItem->click_fn) {
            luaL_unref(L, LUA_REGISTRYINDEX, menuBarItem->click_fn);
            menuBarItem->click_fn = 0;
        }
        if (menuBarItem->click_callback) {
            [statusItem setTarget:nil];
            [statusItem setAction:nil];
            clickDelegate *object = (__bridge_transfer clickDelegate *)menuBarItem->click_callback;
            menuBarItem->click_callback = nil;
            object = nil;
        }
    } else {
        luaL_checktype(L, 2, LUA_TFUNCTION);
        lua_pushvalue(L, 2);
        menuBarItem->click_fn = luaL_ref(L, LUA_REGISTRYINDEX);
        clickDelegate *object = [[clickDelegate alloc] init];
        object.L = L;
        object.fn = menuBarItem->click_fn;
        menuBarItem->click_callback = (__bridge_retained void*) object;
        [statusItem setTarget:object];
        [statusItem setAction:@selector(click:)];
    }
    return 0;
}

void parse_table(lua_State *L, int idx, NSMenu *menu) {
    lua_pushnil(L); // Push a nil to the top of the stack, which lua_next() will interpret as "fetch the first item of the table"
    while (lua_next(L, idx) != 0) {
        // lua_next pushed two things onto the stack, the table item's key at -2 and its value at -1

        // Check that the value is a table
        if (lua_type(L, -1) != LUA_TTABLE) {
            NSLog(@"Error: table entry is not a menu item table");

            // Pop the value off the stack, leaving the key at the top
            lua_pop(L, 1);
            // Bail to the next lua_next() call
            continue;
        }

        // Inspect the menu item table at the top of the stack, fetch the value for the key "title" and push the result to the top of the stack
        lua_getfield(L, -1, "title");
        if (!lua_isstring(L, -1)) {
            NSLog(@"Error: malformed menu table entry");
            // We need to pop two things off the stack - the result of lua_getfield and the table it inspected
            lua_pop(L, 2);
            // Bail to the next lua_next() call
            continue;
        }

        // We have found the title of a menu bar item. Turn it into an NSString and pop it off the stack
        NSString *title = [NSString stringWithUTF8String:lua_tostring(L, -1)];
        lua_pop(L, 1);

        if ([title isEqualToString:@"-"]) {
            [menu addItem:[NSMenuItem separatorItem]];
        } else {
            NSMenuItem *menuItem = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];

            // Check to see if we have a submenu, if so, recurse into it
            lua_getfield(L, -1, "menu");
            if (lua_istable(L, -1)) {
                NSMenu *subMenu = [[NSMenu alloc] initWithTitle:@"HammerspoonSubMenu"];
                parse_table(L, lua_gettop(L), subMenu);
                [menuItem setSubmenu:subMenu];
            }
            lua_pop(L, 1);

            // Inspect the menu item table at the top of the stack, fetch the value for the key "fn" and push the result to the top of the stack
            lua_getfield(L, -1, "fn");
            if (lua_isfunction(L, -1)) {
                clickDelegate *delegate = [[clickDelegate alloc] init];

                // luaL_ref is going to store a reference to the item at the top of the stack and then pop it off. To avoid confusion, we're going to push the top item on top of itself, so luaL_ref leaves us where we are now
                lua_pushvalue(L, -1);
                delegate.fn = luaL_ref(L, LUA_REGISTRYINDEX);
                delegate.L = L;
                [menuItem setTarget:delegate];
                [menuItem setAction:@selector(click:)];
                [menuItem setRepresentedObject:delegate];
            }
            // Pop the result of fetching "fn", off the stack
            lua_pop(L, 1);

            // Check if this item is enabled/disabled, defaulting to enabled
            lua_getfield(L, -1, "disabled");
            if (lua_isboolean(L, -1)) {
                [menuItem setEnabled:lua_toboolean(L, -1)];
            } else {
                [menuItem setEnabled:YES];
            }
            lua_pop(L, 1);

            // Check if this item is checked/unchecked, defaulting to unchecked
            lua_getfield(L, -1, "checked");
            if (lua_isboolean(L, -1)) {
                [menuItem setState:lua_toboolean(L, -1) ? NSOnState : NSOffState];
            } else {
                [menuItem setState:NSOffState];
            }
            lua_pop(L, 1);

            [menu addItem:menuItem];
        }
        // Pop the menu item table off the stack, leaving its key at the top, for lua_next()
        lua_pop(L, 1);
    }
}

void erase_menu_items(lua_State *L, NSMenu *menu) {
    for (NSMenuItem *menuItem in [menu itemArray]) {
        clickDelegate *target = [menuItem representedObject];
        if (target) {
            luaL_unref(L, LUA_REGISTRYINDEX, target.fn);
            [menuItem setTarget:nil];
            [menuItem setAction:nil];
            [menuItem setRepresentedObject:nil];
            target = nil;
        }
        if ([menuItem hasSubmenu]) {
            erase_menu_items(L, [menuItem submenu]);
            [menuItem setSubmenu:nil];
        }
        [menu removeItem:menuItem];
    }
}

/// hs.menubar:setMenu(items)
/// Method
/// Sets the menu for this menubar item to the supplied table, or removes the menu if the argument is nil
///  {{ title = "my menu item", fn = function() print("you clicked!") end }, { title = "other item", fn = some_function } }
static int menubar_set_menu(lua_State *L) {
    menubaritem_t *menuBarItem = luaL_checkudata(L, 1, USERDATA_TAG);
    NSStatusItem *statusItem = (__bridge NSStatusItem*)menuBarItem->menuBarItemObject;

    if (lua_isnil(L, 2)) {
        NSMenu *menu = [statusItem menu];

        if (menu) {
            menuDelegate *delegate = [menu delegate];
            if (delegate) {
                luaL_unref(L, LUA_REGISTRYINDEX, delegate.fn);
                [dynamicMenuDelegates removeObject:delegate];
                [menu setDelegate:nil];
                delegate = nil;
            }
            erase_menu_items(L, menu);
        }

        [statusItem setMenu:nil];
    } else {
        luaL_checktype(L, 2, LUA_TTABLE);

        NSMenu *menu = [[NSMenu alloc] initWithTitle:@"HammerspoonMenuItemMenu"];
        [menu setAutoenablesItems:NO];

        parse_table(L, 2, menu);

        if ([menu numberOfItems] > 0) {
            [statusItem setMenu:menu];
        }
    }

    return 0;
}

/// hs.menubar:setMenuCallback(fn)
/// Method
/// Adds a menu to this menubar item, supplying a callback that will be called when the menu needs to update (i.e. when the user clicks on the menubar item).
/// The callback should return a table describing the structure and properties of the menu. Its format should be identical to that of the argument to hs.menubar:setMenu()
static int menubar_set_menu_callback(lua_State *L) {
    menubaritem_t *menuBarItem = luaL_checkudata(L, 1, USERDATA_TAG);
    NSStatusItem *statusItem = (__bridge NSStatusItem*)menuBarItem->menuBarItemObject;

    luaL_checktype(L, 2, LUA_TFUNCTION);

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"HammerspoonMenuItemDynamicMenu"];
    [menu setAutoenablesItems:NO];

    menuDelegate *delegate = [[menuDelegate alloc] init];
    delegate.L = L;
    lua_pushvalue(L, 2);
    delegate.fn = luaL_ref(L, LUA_REGISTRYINDEX);
    [dynamicMenuDelegates addObject:delegate];

    [statusItem setMenu:menu];
    [menu setDelegate:delegate];

    return 0;
}

/// hs.menubar:delete(menubaritem)
/// Method
/// Removes the menubar item from the menubar and destroys it
static int menubar_delete(lua_State *L) {
    menubaritem_t *menuBarItem = luaL_checkudata(L, 1, USERDATA_TAG);

    NSStatusBar *statusBar = [NSStatusBar systemStatusBar];
    NSStatusItem *statusItem = (__bridge NSStatusItem*)menuBarItem->menuBarItemObject;

    // Remove any click callbackery the menubar item has
    lua_pushcfunction(L, menubar_click_callback);
    lua_pushvalue(L, 1);
    lua_pushnil(L);
    lua_call(L, 2, 0);

    // Remove a menu callback handler if the menubar item has a menu
    NSMenu *menu = [statusItem menu];
    menuDelegate *delegate = [menu delegate];
    if (delegate) {
        luaL_unref(L, LUA_REGISTRYINDEX, delegate.fn);
        [dynamicMenuDelegates removeObject:delegate];
        [menu setDelegate:nil];
    }
    delegate = nil;

    // Remove a menu if the menubar item has one
    lua_pushcfunction(L, menubar_set_menu);
    lua_pushvalue(L, 1);
    lua_pushnil(L);
    lua_call(L, 2, 0);

    [statusBar removeStatusItem:(__bridge NSStatusItem*)menuBarItem->menuBarItemObject];
    menuBarItem->menuBarItemObject = nil;
    menuBarItem = nil;

    return 0;
}

// ----------------------- Lua/hs glue GAR ---------------------

static int menubar_setup(lua_State* __unused L) {
    if (!dynamicMenuDelegates) {
        dynamicMenuDelegates = [[NSMutableArray alloc] init];
    }
    return 0;
}

static int meta_gc(lua_State* __unused L) {
    //FIXME: We should really be removing all menubar items here, as well as doing:
    //[dynamicMenuDelegates removeAllObjects];
    //dynamicMenuDelegates = nil;
    return 0;
}

static int menubar_gc(lua_State *L) {
    lua_pushcfunction(L, menubar_delete) ; lua_pushvalue(L, 1); lua_call(L, 1, 1);
    return 0;
}

static const luaL_Reg menubarlib[] = {
    {"new", menubar_new},

    {}
};

static const luaL_Reg menubar_metalib[] = {
    {"setTitle", menubar_settitle},
    {"setIcon", menubar_seticon},
    {"setTooltip", menubar_settooltip},
    {"clickCallback", menubar_click_callback},
    {"setMenu", menubar_set_menu},
    {"setMenuCallback", menubar_set_menu_callback},
    {"delete", menubar_delete},

    {"__gc", menubar_gc},
    {}
};

static const luaL_Reg meta_gclib[] = {
    {"__gc", meta_gc},

    {}
};

/* NOTE: The substring "hs_menubar_internal" in the following function's name
         must match the require-path of this file, i.e. "hs.menubar.internal". */

int luaopen_hs_menubar_internal(lua_State *L) {
    menubar_setup(L);

    // Metatable for created objects
    luaL_newlib(L, menubar_metalib);
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");
    lua_setfield(L, LUA_REGISTRYINDEX, USERDATA_TAG);

    // Table for luaopen
    luaL_newlib(L, menubarlib);
    luaL_newlib(L, meta_gclib);
    lua_setmetatable(L, -2);

    return 1;
}
