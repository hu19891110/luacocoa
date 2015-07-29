//
//  luaoc_instance.h
//  luaoc
//
//  Created by Wangxh on 15/7/28.
//  Copyright (c) 2015年 sw. All rights reserved.
//

#import "lua.h"

#define LUAOC_INSTANCE_METATABLE_NAME "oc.instance"

int luaopen_luaoc_instance(lua_State *L);

void luaoc_push_instance(lua_State *L, id v);

/** push super of value at index, value must be id or super data */
void luaoc_push_super(lua_State *L, int index);
