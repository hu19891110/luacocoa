//
//  luaoc_helper.m
//  luaoc
//
//  Created by Wangxh on 15/7/28.
//  Copyright (c) 2015年 sw. All rights reserved.
//

#import "luaoc_helper.h"
#import "luaoc_class.h"
#import "luaoc_instance.h"
#import "luaoc_struct.h"

#import "lauxlib.h"

#import <objc/runtime.h>
#import <Foundation/Foundation.h>

static int _msg_send(lua_State* L, SEL selector) {
  // call intenally, the stack should have and only have receiver and args
  id target = *(id*)lua_touserdata(L, 1);
  NSMethodSignature* sign = [target methodSignatureForSelector: selector];
  if (!sign){
    luaL_error(L, "'%s' has no method '%s'",
        object_getClassName(target), sel_getName(selector));
  }

  NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:sign];
  [invocation setTarget:target];
  [invocation setSelector:selector];

  NSUInteger argCount = [sign numberOfArguments];
  void **arguements = (void**)alloca(sizeof(void*) * argCount);
  for (NSUInteger i = 2; i < argCount; ++i) {
    arguements[i] =
      luaoc_copy_toobjc(L, (int)i, [sign getArgumentTypeAtIndex:i], NULL);
    [invocation setArgument:arguements[i] atIndex:i];
  }

  @try {
    [invocation invoke];
  }
  @catch (NSException* exception) {
    luaL_error(L, "Error invoking '%s''s method '%s'. reason is:\n%s",
        object_getClassName(target),
        sel_getName(selector),
        [[exception reason] UTF8String]);
  }

  for (NSUInteger i = 2; i < argCount; ++i) {
    free(arguements[i]);
  }

  NSUInteger retLen = [sign methodReturnLength];
  if (retLen > 0){
    void* buf = alloca(retLen);
    [invocation getReturnValue:buf];
    luaoc_push_obj(L, [sign methodReturnType], buf);
  } else{
    lua_pushnil(L);
  }

  return 1;
}

int luaoc_msg_send(lua_State* L){
  id* ud = (id*)lua_touserdata(L, 1);

  if (!ud) { luaL_argerror(L, 1, "msg receiver must be objc object!"); }

  if (luaL_getmetafield(L, 1, "__type") != LUA_TNUMBER) {
    luaL_error(L, "can't found metaTable!");
  }
  LUA_INTEGER tt = lua_tointeger(L, -1);
  lua_pop(L, 1);

  const char* selName = lua_tostring(L, lua_upvalueindex(1));
  SEL selector = sel_getUid(selName);
  if (tt == luaoc_super_type){
    Method selfMethod = class_getInstanceMethod([*ud class], selector);
    if (NULL == selfMethod) luaL_error(L, "unknown selector %s", selName);
    Method superMethod = class_getInstanceMethod(*(ud+1), selector);
    if (superMethod && superMethod != selfMethod){
      IMP selfMethodIMP = method_getImplementation(selfMethod);
      IMP superMethodIMP = method_getImplementation(superMethod);
      method_setImplementation(selfMethod, superMethodIMP);
      int ret = _msg_send(L, selector);
      method_setImplementation(selfMethod, selfMethodIMP);
      return ret;
    } else {
      return _msg_send(L, selector);
    }
  } else if (tt == luaoc_class_type || tt == luaoc_instance_type) {
    return _msg_send(L, selector);
  } else {
    luaL_error(L, "unsupported msg receiver type");
  }
  return 0;
}

void* luaoc_copy_toobjc(lua_State *L, int index, const char *typeDescription, int *outSize) {
  void* value = NULL;
  if (outSize == NULL) outSize = (int*)alloca(sizeof(int));     // prevent NULL condition in deal
  *outSize = 0;

  if (lua_isnoneornil(L, index)) { // if nil, return a pointer ref to NULL pointer, it also can treat as number 0
    *outSize = sizeof(void*); value = calloc(sizeof(void*), 1);
    return value;
  }

  int i = 0;

#define CONVERT_TO_TYPE( type, lua_func)                 \
  *outSize = sizeof(type); value = malloc(sizeof(type)); \
  *((type *)value) = (type)lua_func(L, index)

#define INTEGER_CASE(encoding, type) case encoding: { CONVERT_TO_TYPE(type, lua_tointeger); return value; }
#define NUMBER_CASE(encoding, type)  case encoding: { CONVERT_TO_TYPE(type, lua_tonumber); return value; }
#define BOOL_CASE(encoding, type)    case encoding: { CONVERT_TO_TYPE(type, lua_toboolean); return value; }

  while ( typeDescription[i] ) {
    switch( typeDescription[i] ){
      INTEGER_CASE(_C_CHR, char)
      INTEGER_CASE(_C_UCHR, unsigned char)
      INTEGER_CASE(_C_SHT, short)
      INTEGER_CASE(_C_USHT, unsigned short)
      INTEGER_CASE(_C_INT, int)
      INTEGER_CASE(_C_UINT, unsigned int)
      INTEGER_CASE(_C_LNG, long)
      INTEGER_CASE(_C_ULNG, unsigned long)
      INTEGER_CASE(_C_LNG_LNG, long long)
      INTEGER_CASE(_C_ULNG_LNG, unsigned long long)
      NUMBER_CASE (_C_FLT, float)
      NUMBER_CASE (_C_DBL, double)
      BOOL_CASE   (_C_BOOL, bool)
      case _C_CHARPTR: {
        *outSize = sizeof(char*); value = malloc(sizeof(char*));
        *(const char**)value = lua_tostring(L, index);
        return value;
      }
      case _C_PTR: {
        // TODO: how to deal ref to a value, or ref to out val?
        // now consider use userdata represent pointer, like pass by ref
        *outSize = sizeof(void*); value = calloc(sizeof(void*), 1);
        switch( lua_type(L, index) ){
          case LUA_TLIGHTUSERDATA:
          case LUA_TUSERDATA: { // TODO: need to think how to deal
            *(void**)value = lua_touserdata(L, index);
            return value;
          }
          case LUA_TNONE:
          case LUA_TNIL: return value;
          default: {
            return value;
          }
        }
      }
      case _C_CLASS:
      case _C_ID: {
        *outSize = sizeof(id); value = calloc(sizeof(id), 1);
        switch (lua_type(L, index)){
          case LUA_TLIGHTUSERDATA:
            *(id*)value = *(id*)lua_touserdata(L, index);
            return value;
          case LUA_TUSERDATA:
            *(id*)value = *(id*)lua_touserdata(L, index);
            return value;
            // TODO: bind table type to array and dict, value type to value

          case LUA_TBOOLEAN:
            *(id*)value = [NSNumber numberWithBool:lua_toboolean(L, index)];
            return value;
          case LUA_TNUMBER:
            *(id*)value = [NSNumber numberWithDouble:lua_tonumber(L, index)];
            return value;
          case LUA_TSTRING:
            *(id*)value = [NSString stringWithUTF8String:lua_tostring(L, index)];
            return value;
          case LUA_TTABLE:{
           BOOL dictionary = NO;

           lua_pushvalue(L, index); // Push the table reference on the top
           lua_pushnil(L);  /* first key */
           while (!dictionary && lua_next(L, -2)) {
             if (lua_type(L, -2) != LUA_TNUMBER) {
               dictionary = YES;
               lua_pop(L, 2); // pop key and value off the stack
             }
             else {
               lua_pop(L, 1);
             }
           }

           if (dictionary) {
             *(id*)value = [NSMutableDictionary dictionary];

             lua_pushnil(L);  /* first key */
             while (lua_next(L, -2)) {
               id *key = (id*)luaoc_copy_toobjc(L, -2, "@", nil);
               id *object = (id*)luaoc_copy_toobjc(L, -1, "@", nil);
               if (*key && *object) // ignore NULL kv
                 [*(id*)value setObject:*object forKey:*key];
               lua_pop(L, 1); // Pop off the value
               free(key);
               free(object);
             }
           } else {
             *(id*)value = [NSMutableArray array];

             size_t len = lua_rawlen(L, -1);
             for (size_t i = 1; i <= len; ++i) {
               lua_rawgeti(L, -1, i);
               id *object = (id*)luaoc_copy_toobjc(L, -1, "@", nil);
               [*(id*)value addObject:*object];
               free(object);
             }
           }

           lua_pop(L, 1); // Pop the table reference off
           break;
          }
          case LUA_TNIL: case LUA_TNONE:
          default: return value;
        }
      }
      case _C_SEL:{
        *outSize = sizeof(SEL); value = calloc(sizeof(SEL), 1);
        *(const char**)value = lua_tostring(L, index);
        if (*(char**)value) {
          *(SEL*)value = sel_getUid(*(char**)value);
        }
        return value;
      }
      // TODO:
      case _C_STRUCT_B:
      default: {
        break;
      }
    }
    ++i;
  }
  DLOG( "undeal encoding: %s", typeDescription);
  return value;
}

void luaoc_push_obj(lua_State *L, const char *typeDescription, void* buffer) {

#define PUSH_INTEGER(encoding, type) case encoding: lua_pushinteger(L, *(type*)buffer); return;
#define PUSH_NUMBER(encoding, type) case encoding: lua_pushnumber(L, *(type*)buffer); return;
#define PUSH_POINTER(encoding, type, luafunc) \
  case encoding: {if (*(type*)buffer == NULL) lua_pushnil(L); else luafunc(L, *(type*)buffer);} return;

  int i = 0;
  while(typeDescription[i]) {
    switch( typeDescription[i] ){
      case _C_BOOL:
        lua_pushboolean(L, *(bool*)buffer);
        return;
      PUSH_INTEGER(_C_CHR     , char)
      PUSH_INTEGER(_C_UCHR    , unsigned char)
      PUSH_INTEGER(_C_SHT     , short)
      PUSH_INTEGER(_C_USHT    , unsigned short)
      PUSH_INTEGER(_C_INT     , int)
      PUSH_INTEGER(_C_UINT    , unsigned int)
      PUSH_INTEGER(_C_LNG     , long)
      PUSH_INTEGER(_C_ULNG    , unsigned long)
      PUSH_INTEGER(_C_LNG_LNG , long long)
      PUSH_INTEGER(_C_ULNG_LNG, unsigned long long)
      PUSH_NUMBER(_C_FLT , float)
      PUSH_NUMBER(_C_DBL , double)
      PUSH_POINTER(_C_ID, id, luaoc_push_instance)
      PUSH_POINTER(_C_CLASS, Class, luaoc_push_class)
      PUSH_POINTER(_C_PTR, void*, lua_pushlightuserdata)
      PUSH_POINTER(_C_CHARPTR, char*, lua_pushstring)
      case _C_SEL:
        if (*(SEL*)buffer == NULL) lua_pushnil(L);
        else lua_pushstring(L, sel_getName(*(SEL*)buffer));
        return;
      case _C_VOID:
        lua_pushnil(L); return;
      case _C_STRUCT_B:
        luaoc_push_struct(L, typeDescription+i, buffer);
        return;
//#define _C_UNDEF    '?'
//#define _C_ATOM     '%'
//#define _C_ARY_B    '['
//#define _C_ARY_E    ']'
//#define _C_UNION_B  '('
//#define _C_UNION_E  ')'
//#define _C_STRUCT_B '{'
//#define _C_STRUCT_E '}'
//#define _C_VECTOR   '!'
      default: {
        break;
      }
    }
    ++i;
  }
  DLOG("unable convert typeencoding %s", typeDescription);
  lua_pushnil(L);
}

#pragma mark - DEBUG
void luaoc_print(lua_State* L, int index) {
  switch( lua_type(L, index) ){
    case LUA_TNIL: {
      printf("nil");
      break;
    }
    case LUA_TNUMBER: {
      printf("%lf", lua_tonumber(L, index));
      break;
    }
    case LUA_TBOOLEAN: {
      printf(lua_toboolean(L, index) ? "true":"false");
      break;
    }
    case LUA_TSTRING: {
      printf("%s", lua_tostring(L, index));
      break;
    }
    case LUA_TTABLE: {
      luaoc_print_table(L, index);
      break;
    }
    case LUA_TFUNCTION: {
      printf("function(%p)", lua_topointer(L, index));
      break;
    }
    case LUA_TUSERDATA: {
      printf("userdata(%p)", lua_touserdata(L, index));
      break;
    }
    case LUA_TLIGHTUSERDATA: {
      printf("pointer(%p)", lua_touserdata(L, index));
      break;
    }
    case LUA_TTHREAD: {
      printf("thread(%p)", lua_topointer(L, index));
      break;
    }
    case LUA_TNONE:
    default: {
      printf("invalid index\n");
      break;
    }
  }
}

void luaoc_print_table(lua_State* L, int index) {
  if (lua_type(L, index) == LUA_TTABLE) {
    int top = lua_gettop(L);
    if (index < 0) index = top + index + 1;

    printf("table(%p):{\n", lua_topointer(L, index));
    lua_pushnil(L);
    while(lua_next(L, index) != 0) {
      printf("\t");
      luaoc_print(L, -2);
      printf("\t:\t");
      luaoc_print(L, -1);
      printf("\n");

      lua_pop(L, 1);
    }
    printf("}");

  } else{
    printf("print not table\n");
  }
}

void luaoc_dump_stack(lua_State* L) {
  int top = lua_gettop(L);
  for (int i = 1; i<=top; ++i){
    printf("stack %d:\n", i);
    luaoc_print(L, i);
    printf("\n");
  }
}

