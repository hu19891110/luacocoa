//
//  luaoc_class.m
//  luaoc
//
//  Created by SolaWing on 15/7/28.
//  Copyright (c) 2015年 sw. All rights reserved.
//

#import "luaoc_class.h"
#import "lua.h"
#import "lauxlib.h"

#import <string.h>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>

#import "luaoc_helper.h"
#import "luaoc.h"

#import "luaoc_instance.h"
#import "luaoc_encode.h"

#define LOADED_CLASS_TABLE   "oc.loadedCls"
#define kClassMethodIndex    "__cmsg"
#define kInstanceMethodIndex "__imsg"

/** push lua implement function according to parameter, or nil when not found */
static void luaoc_push_lua_func(lua_State *L, Class cls, SEL sel, bool isClassMethod);

/** cls.methodType[name] = func. func at the stack top. cls at the clsIndex. */
static void luaoc_set_lua_func(lua_State *L, int clsIndex, const char* name, bool isClassMethod);

//#define NO_USE_FFI
#ifndef NO_USE_FFI
#pragma mark - FFI MSG
//#import "ffi.h"
#import "ffi_wrap.h"

// the following two dict used to cache generated closureFunc and ffi_type
static NSMutableDictionary* luaFuncDict; // encoding => closureFunc
static void luaoc_msg_from_oc(ffi_cif *cif, void* ret, void** args, void* ud) {
  if (![NSThread isMainThread]) {
      NSLog(@"[WARN] call lua method on non-main thread!!\n"
             "now dispatch to main thread. may deadlock");
      dispatch_sync( dispatch_get_main_queue(), ^{
          luaoc_msg_from_oc(cif, ret, args, ud);
      });
      return ;
  }

  id self = *(id*)args[0];
  SEL _cmd = *(SEL*)args[1];
  lua_State *const L = gLua_main_state;

  LUA_PUSH_STACK(L);

  Class cls = [self class];
  bool isClass = cls == self;
  if (isClass) {
      luaoc_push_class(L, cls);
  }
  else {
      luaoc_push_instance(L, self);
      lua_getuservalue(L, -1);
      if ( lua_rawgetfield(L, -1, "__superinfo") == LUA_TTABLE &&
           lua_rawgetfield(L, -1, sel_getName(_cmd)) == LUA_TUSERDATA )
      { // find super call info. use the super class to search method
          cls = *( ((id*)lua_touserdata(L, -1))+1 );
      }
      lua_settop(L, LUA_START_INDEX(L) + 1); // keep instance
  }

  luaoc_push_lua_func(L, cls, _cmd, isClass);
  if (lua_isnil(L, -1)) {
      LUA_POP_STACK(L, 0);
      DLOG("can't found lua func"); return;
  }
  lua_insert(L, -2);

  NSMethodSignature* sign = [self methodSignatureForSelector:_cmd];
  int argCount = (int)[sign numberOfArguments];

  for (int i = 2; i<argCount; ++i) {
    const char* encoding = [sign getArgumentTypeAtIndex:i];
    luaoc_push_obj(L, encoding, args[i]);
  }
  size_t retLen = [sign methodReturnLength];
  if (lua_pcall(L, argCount-1, retLen>0?1:0, 0) != 0) {
    DLOG("%s call lua func %s error:\n  %s",
        class_getName(cls), sel_getName(_cmd), lua_tostring(L, -1) );
  } else if (retLen>0) {
    const char* retType = [sign methodReturnType];
    void* buf = luaoc_copy_toobjc(L, -1, retType, &retLen);
    memcpy(ret, buf, retLen);

    if ( strcmp(retType, "@") == 0 && *(id*)buf != NULL) {
      const char * selName = sel_getName(_cmd);
      int n;
      if ( ((n = 4, strncmp(selName, "init", 4) == 0) ||
                    strncmp(selName, "copy", 4) == 0  ||
            (n = 3, strncmp(selName, "new",  3) == 0) ||
            (n = 11, strncmp(selName, "mutableCopy", n) == 0)) &&
          !islower(selName[n]) ) {
        // according to oc owner rule, this object is owned by caller. so lua
        // don't own it. lua will return a +0 object. so retain it.
        [*(id*)buf retain];
        // DLOG("%s retain %p: %lld", selName, *(id*)buf, (UInt64)[*(id*)buf retainCount]);
      }
    }

    free(buf);
  }
  LUA_POP_STACK(L, 0);
}

static IMP imp_for_encoding(const char* encoding){
  NSString *str = [NSString stringWithUTF8String:encoding];
  NSValue *imp = luaFuncDict[str];
  if (imp) return [imp pointerValue]; // return cached func pointer

  IMP code_ptr = create_imp_for_encoding(encoding, luaoc_msg_from_oc, NULL);
  if (code_ptr) {
      luaFuncDict[str] = [NSValue valueWithPointer:code_ptr];
  }
  return code_ptr;
}

#else
#pragma mark - NON-FFI MSG float struct not work in x64
// NOTE: NOW CONVERT TO USE FFI IMP, NON-FFI SIDE MAY NOT MAINTAIN
#ifdef __LP64__
    #define _ASM_WRAP(name) static void a##name () {\
      __asm__("movb $1, %al \n\t popq %rbp\n\t jmp " PP_STR(_##name)); } // HACK, now x64 can save xmm value in stack
    #define ASM_WRAP(name) _ASM_WRAP(name) // ensure param expand
#else
    #define ASM_WRAP(name)
#endif
    typedef struct { char b[8]; } _buf_8;
    typedef struct { char b[16]; } _buf_16;
    typedef struct { char b[32]; } _buf_32;
/** though here use va_arg, but in objc, the actual call will be cast to correct
 *  parameter type, and not the va_list form.
 *  test in x86, the float won't promote to double. now fix to support it
 *  test in x64, there has a xmm register, and float type even not
 *    get pass for cast-call!! it seem to unpossible except write a assemble func.
 *    struct contain float can even wrose!
 *    so now float relevant func may have bugs
 */
static const char* luaoc_method_call(lua_State *L, id receiver, SEL _cmd, va_list ap, void* retBuf, size_t bufLen) {
  if (![NSThread isMainThread])
    NSLog(@"[WARN] pcall lua method on non-main thread!!");

  if (retBuf) memset(retBuf, 0, bufLen);

  Class cls = [receiver class];
  bool isClass = cls == receiver;
  luaoc_push_lua_func(L, cls, _cmd, isClass);
  if (lua_isnil(L, -1)) return "can't found func!";

  if (isClass) luaoc_push_class(L, cls);
  else luaoc_push_instance(L, receiver);

  NSMethodSignature* sign = [receiver methodSignatureForSelector:_cmd];
  int argCount = (int)[sign numberOfArguments];

  void* buffer = NULL;
#define VAR_TYPE(type)                  \
  buffer = alloca(sizeof(type));        \
  *(type*)buffer = va_arg(ap, type);    \
  goto pcall_end_while

  for (int i = 2; i < argCount; ++i) {
    // get arg from encoding
    const char* encoding = [sign getArgumentTypeAtIndex:i];
    while(*encoding){
      switch( *encoding ){
        case _C_BOOL:
        case _C_CHR:
        case _C_UCHR:
        case _C_SHT:
        case _C_USHT:
        case _C_INT:
        case _C_UINT:
          VAR_TYPE(int);
        case _C_LNG:
        case _C_ULNG:
          VAR_TYPE(long);
        case _C_LNG_LNG:
        case _C_ULNG_LNG:
          VAR_TYPE(long long);
        case _C_FLT:
          VAR_TYPE(float); // HACK: in x86, cast call won't promote float to double
        case _C_DBL:
          VAR_TYPE(double);
          // buffer = alloca(sizeof(double));
          // *(double*)buffer = va_arg(ap, double); // get double but in memory it's float...
          // *(double*)buffer = *(float*)buffer;     // convert float in memory to double type
          // goto pcall_end_while;
        case _C_PTR:
        case _C_CHARPTR:
        case _C_ID:
        case _C_SEL:
        case _C_CLASS:
        case _C_ARY_B:
          VAR_TYPE(id);
        case _C_STRUCT_B:
          // HACK, float and other save in different register. so for struct
          // need to get each primitive field
          // NOTE this method may have bug. recommand use ffi version.
          buffer = alloca(luaoc_get_one_typesize(encoding, NULL, NULL));
          void* bufferPtr = buffer;

#define CASE_TYPE(encode, type, apType) case encode: \
    *((type*)bufferPtr) = va_arg(ap, apType); bufferPtr+=sizeof(type); break;

          const char* structBegin = encoding;
          while (*encoding){
            switch( *encoding ){
              CASE_TYPE(_C_BOOL     ,bool, int)
              CASE_TYPE(_C_CHR      ,char, int)
              CASE_TYPE(_C_UCHR     ,unsigned char, int)
              CASE_TYPE(_C_SHT      ,short, int)
              CASE_TYPE(_C_USHT     ,unsigned short, int)
              CASE_TYPE(_C_INT      ,int , int)
              CASE_TYPE(_C_UINT     ,unsigned int, int)
              CASE_TYPE(_C_LNG      ,long, long)
              CASE_TYPE(_C_ULNG     ,unsigned long, unsigned long)
              CASE_TYPE(_C_LNG_LNG  ,long long, long long)
              CASE_TYPE(_C_ULNG_LNG ,unsigned long long, unsigned long long)
              CASE_TYPE(_C_FLT      ,float, float) // x86 simulator, not promote to double
              CASE_TYPE(_C_DBL      ,double, double)
              case _C_PTR:
                luaoc_get_one_typesize(encoding+1, &encoding, NULL);
                --encoding; // ++ encoding at end
              case _C_CHARPTR:
              case _C_ID:
              case _C_SEL:
              case _C_CLASS:
                *(id*)bufferPtr = va_arg(ap, id); bufferPtr+=sizeof(id);
                break;
              case _C_ARY_B:
              case _C_UNION_B:
                return "union and array not supported currently";
              case _C_STRUCT_B: {
                encoding = strchr(encoding+1, '=');
                if (!encoding) return "struct encoding error, can't find =";
              }
              default: break;
            }
            ++encoding;
          }
          encoding = structBegin; // restore encoding for later push use
          goto pcall_end_while;
        case _C_UNION_B:
          return "union type in method_call not support!";
        default: {
          break;
        }
      }
      ++encoding;
    }
pcall_end_while:
    if (!*encoding) return "pcall unsupported encoding!"; // use out encoding

    luaoc_push_obj(L, encoding, buffer);
  }

  int retCount = [sign methodReturnLength]>0?1:0;
  if (lua_pcall(L, argCount-1, retCount, 0) != 0) {
    const char* err = lua_tostring(L, -1);
    lua_pop(L, 1);
    return err;
  } else if (retCount && retBuf) {
    size_t outLen;
    const char* returnType = [sign methodReturnType];
    void* buf = luaoc_copy_toobjc(L, -1, returnType, &outLen);
    memcpy(retBuf, buf, outLen);
    free(buf);
    lua_pop(L, 1);
  }

  return NULL;
}


#define LUAOC_METHOD_NAME(returnType) luaoc_##returnType##_call

#define LUAOC_TYPE_CALL(_type_)                                             \
_type_ LUAOC_METHOD_NAME(_type_)(id self, SEL _cmd, ...) {           \
  _type_ returnValue;                                                       \
  va_list args;                                                             \
  va_start(args, _cmd);   int a=0; if (a) va_arg(args, int);                \
  const char* result = luaoc_method_call(gLua_main_state, self, _cmd, args, \
      &returnValue, sizeof(_type_));                                        \
  va_end(args);                                                             \
                                                                            \
  if (result) {                                                             \
    luaL_error(gLua_main_state, "Error calling '%s' on '%s'n%s",            \
        _cmd, [[self description] UTF8String],                              \
        result);                                                            \
  }                                                                         \
  return returnValue;                                                       \
}                                                                           \
ASM_WRAP(LUAOC_METHOD_NAME(_type_))

LUAOC_TYPE_CALL(id)
LUAOC_TYPE_CALL(long)
LUAOC_TYPE_CALL(int64_t)
LUAOC_TYPE_CALL(float)
LUAOC_TYPE_CALL(double)
LUAOC_TYPE_CALL(_buf_8)
LUAOC_TYPE_CALL(_buf_16)
LUAOC_TYPE_CALL(_buf_32)
LUAOC_TYPE_CALL(CGPoint)
LUAOC_TYPE_CALL(CGRect)

#ifdef __LP64__
#define LUAOC_IMP_METHOD_NAME(returnType) aluaoc_##returnType##_call
#else
#define LUAOC_IMP_METHOD_NAME LUAOC_METHOD_NAME
#endif

static IMP imp_for_encoding(const char* encoding) {
  while (*encoding){
    switch( *encoding ){
      case _C_BOOL:
      case _C_CHR:
      case _C_UCHR:
      case _C_SHT:
      case _C_USHT:
      case _C_INT:
      case _C_UINT:
      case _C_PTR:
      case _C_CHARPTR:
      case _C_ID:
      case _C_SEL:
      case _C_CLASS:
      case _C_ARY_B:
      case _C_VOID:
        return (IMP)LUAOC_IMP_METHOD_NAME(id);
      case _C_LNG:
      case _C_ULNG:
        return (IMP)LUAOC_IMP_METHOD_NAME(long);
      case _C_LNG_LNG:
      case _C_ULNG_LNG:
        return (IMP)LUAOC_IMP_METHOD_NAME(int64_t);
      case _C_FLT:
        return (IMP)LUAOC_IMP_METHOD_NAME(float);
      case _C_DBL:
        return (IMP)LUAOC_IMP_METHOD_NAME(double);
      case _C_STRUCT_B: {
#ifdef __LP64__
        char* structName;
        NSUInteger returnTypeSize = luaoc_get_one_typesize(encoding, NULL, &structName);
        IMP imp = NULL;
        if (strcmp(structName, "CGPoint") == 0) imp = LUAOC_IMP_METHOD_NAME(CGPoint);
        else if (strcmp(structName, "CGSize") == 0) imp = LUAOC_IMP_METHOD_NAME(CGPoint);
        // CGRect not use xmm register
        // else if (strcmp(structName, "CGRect") == 0) imp = LUAOC_IMP_METHOD_NAME(CGRect);
        free(structName);
        if (imp) return imp;
#else
        NSUInteger returnTypeSize = luaoc_get_one_typesize(encoding, NULL, NULL);
#endif
        if (returnTypeSize<=8) return (IMP)LUAOC_IMP_METHOD_NAME(_buf_8);
        else if (returnTypeSize <= 16) return (IMP)LUAOC_IMP_METHOD_NAME(_buf_16);
        else if (returnTypeSize <= 32) return (IMP)LUAOC_IMP_METHOD_NAME(_buf_32);
        else { DLOG("unsupported struct type %s", encoding); return NULL; }
      }
      case _C_BFLD:
      case _C_UNION_B:
        DLOG("unsupported encoding type!");
      case '\0':
        return NULL;
      default: break;
    }
    ++encoding;
  }
  return NULL;
}

#endif
#pragma mark - class luaoc convert
void luaoc_push_class(lua_State *L, Class cls) {
  if (NULL == cls) {
    lua_pushnil(L);
    return;
  }

  LUA_PUSH_STACK(L);
  if (!luaL_getmetatable(L, LUAOC_CLASS_METATABLE_NAME)) {
    // no meta table, there is some wrong , or call this method when not open
    DLOG("ERROR: can't get metaTable, do you open oc lib?");
    LUA_POP_STACK(L, 1);
    return;
  }

  lua_rawgetfield(L, LUA_REGISTRYINDEX, LOADED_CLASS_TABLE); // : meta loaded

  if (lua_rawgetp(L, -1, cls) == LUA_TNIL){ // no obj, bind new
    *(Class*)(lua_newuserdata(L, sizeof(Class))) = cls;
    lua_pushvalue(L, LUA_START_INDEX(L)+1);
    lua_setmetatable(L, -2);                        // + ud ; set ud meta

    lua_newtable(L);
    lua_setuservalue(L, -2);                        // ; set ud uservalue a newtable

    lua_pushvalue(L, -1);
    lua_rawsetp(L, LUA_START_INDEX(L)+2, cls);      // loaded[p] = ud
  }

  LUA_POP_STACK(L, 1);  // keep ud at the top
}

Class luaoc_toclass(lua_State *L, int index) {
  Class* ud = (Class*)luaL_testudata(L, index, LUAOC_CLASS_METATABLE_NAME);
  if (NULL == ud) return NULL;
  return *ud;
}

#pragma mark - class search table
static int index_class_by_name(lua_State *L){
  const char *className = luaL_checkstring(L, 2);
  Class cls = objc_getClass(className);
  if (cls) {
    luaoc_push_class(L, cls);
  }else {
    DLOG("unknown class name: '%s', "
         "did you spell correct or link the relevant framework?", className);
    lua_pushnil(L);
  }
  return 1;
}

/** lua inherited class dealloc method.
 *  use this can avoid having to call super dealloc
 *
 *  lua code can add dealloc lua function to class index value.
 *  instead of overwritting oc dealloc method */
static void luaclass_dealloc(id self, SEL _cmd) {

    // [super dealloc], this method is the rootLuaClass dealloc method.
    SEL sel = sel_getUid("rootLuaClass");
    Class superClass = ((Class(*)(id,SEL))(class_getMethodImplementation([self class], sel)))(self, sel);
    superClass = [superClass superclass];

    // call lua side dealloc. ensure execute on main thread
    dispatch_block_t luaDealloc = ^{
        Class cls = [self class];
        lua_State*const L = gLua_main_state;
        lua_rawgetfield(L, LUA_REGISTRYINDEX, LOADED_CLASS_TABLE);
        int top = lua_gettop(L);
        do {
            if (lua_rawgetp(L, -1, cls) == LUA_TUSERDATA){
                lua_getuservalue(L, -1);
                if (lua_rawgetfield(L, -1, "dealloc") == LUA_TFUNCTION){
                    luaoc_push_instance(L, self);
                    if (lua_pcall(L, 1, 0, 0) != 0) {
                        DLOG("%s call lua func dealloc error:\n  %s",
                                class_getName(cls), lua_tostring(L, -1) );
                        lua_pop(L,1);
                    }
                }
            }
            cls = [cls superclass];
            lua_settop(L, top);
        }while (cls != superClass);
        lua_pop(L, 1);
    };
    if ([NSThread isMainThread]) luaDealloc();
    else {
        dispatch_sync(dispatch_get_main_queue(), luaDealloc);
    }


    IMP superDealloc = class_getMethodImplementation(
            superClass, @selector(dealloc));
    ((void(*)(id,SEL))superDealloc)(self, _cmd);
}

/** add protocols to class
 *
 * @param 1: class or class name
 * @param 2...: one or more protocol names
 */
static int add_protocol(lua_State *L){
  Class cls = luaoc_toclass(L, 1);
  if (!cls) cls = objc_getClass(luaL_checkstring(L, 1));
  if ( unlikely( !cls )) {
      LUAOC_ARGERROR( 1, "can't found class to add protocols" );
  }

  for (int i = 2, top = lua_gettop(L); i <= top; ++i) {
    Protocol *protocol = objc_getProtocol(luaL_checkstring(L, i));
    if ( unlikely( !protocol )) LUAOC_ARGERROR( i,
        "can't found protocol. Hint: in oc file may need to use this protocol");
    class_addProtocol(cls, protocol);
  }

  return 0;
}

/** define a new class.
 *
 * @param 1: self (class_table)
 * @param 2: class name
 * @param 3: super class or super class name. default to NSObject
 * @param 4...: zero or more protocol names
 * @return new class userdata
 */
static int new_class(lua_State *L){
  const char * className = luaL_checkstring(L, 2);
  Class cls = objc_getClass(className);
  if (!cls) {
    Class superClass;
    switch( lua_type(L, 3) ){
      case LUA_TUSERDATA: {
        superClass = luaoc_toclass(L, 3);
        break;
      }
      case LUA_TSTRING: {superClass = objc_getClass(lua_tostring(L, 3)); break;}
      default: {
        superClass = [NSObject class];
        break;
      }
    }
    if ( unlikely( !superClass )) LUAOC_ARGERROR( 3, "can't convert to class" );

    cls = objc_allocateClassPair(superClass, className, 0);

    IMP superDealloc = class_getMethodImplementation(superClass, @selector(dealloc));
    if (superDealloc != (IMP)luaclass_dealloc) {
        class_addMethod(cls, @selector(dealloc), (IMP)luaclass_dealloc, "v@:");
        class_addMethod(cls, sel_getUid("rootLuaClass"), imp_implementationWithBlock(^Class(id self){
            return cls;
        }), "#@:");
    }

    objc_registerClassPair(cls);
  }
  luaoc_push_class(L, cls);
  if (lua_gettop(L) > 4) { // have protocols
    lua_pushcfunction(L, add_protocol);
    lua_pushvalue(L, -2);
    lua_rotate(L, 4, 3); // push cls func cls before protocols
    // call add_protocol with cls and protocols, left cls at top
    lua_call(L, lua_gettop(L) - 5, 0);
  }
  return 1;
}

static int name(lua_State *L){
  if (lua_getmetatable(L, 1)) {
    lua_pushstring(L, "__type");
    if (lua_rawget(L, -2) == LUA_TNUMBER) {
      switch( lua_tointeger(L, -1) ){
        case luaoc_class_type: {
          lua_pushstring(L, class_getName(*(Class*)(lua_touserdata(L, 1))));
          return 1;
        }
        case luaoc_instance_type: { // 对于聚合类, 实例的类可能不是聚合类名
          lua_pushstring(L, object_getClassName(*(id*)(lua_touserdata(L,1))));
          return 1;
        }
        case luaoc_super_type: {
          lua_pushstring(L, class_getName(*(((Class*)lua_touserdata(L, 1)) + 1) ));
          return 1;
        }
        default: {
          break;
        }
      }
    }
  }
  lua_pushnil(L);
  return 1;
}

static const luaL_Reg ClassTableMetaMethods[] = {

  {"__index", index_class_by_name},
  {"__call", new_class},
  {NULL, NULL}
};

static const luaL_Reg ClassTableMethods[] = {
  {"name", name},
  {"addProtocol", add_protocol},
  {NULL, NULL}
};

#pragma mark - class meta func
static const char* find_override_method_encoding(Class cls, SEL selector, bool isClassMethod){
  Method m = isClassMethod ? class_getClassMethod(cls, selector)
                           : class_getInstanceMethod(cls, selector);
  if (m) return method_getTypeEncoding(m);

  // find in protocol
  do {
    Protocol** proto = class_copyProtocolList(cls, NULL);
    if (proto){
      Protocol** proto_it = proto;
      while(*proto_it){
        // look at objc header, objc_method just have more field of IMP
        struct objc_method_description mdes =
          protocol_getMethodDescription(*proto_it, selector, YES, !isClassMethod);
        if (!mdes.name) mdes =
          protocol_getMethodDescription(*proto_it, selector, NO, !isClassMethod);
        if (mdes.name){
          free(proto);
          return mdes.types;
        }
        ++proto_it;
      }
      free(proto);
    }

    cls = class_getSuperclass(cls);
  } while(cls);
  return NULL;
}

/** just overwrite it, in imp, search for the cls luafunc with luaName
 *  OC old imp save in selector prefix with OC */
static bool override(Class cls, const char* selName, bool isClassMethod, const char* addEncoding) {
  NSCParameterAssert(cls);
  NSCParameterAssert(selName);

  SEL sel =  sel_getUid(selName);

  const char *encoding = find_override_method_encoding(cls, sel, isClassMethod);

  if (NULL == encoding) {
      if (addEncoding) {
          encoding = addEncoding; // new method, use given encoding
      } else {
          return false;
      }
  }

  IMP imp = imp_for_encoding(encoding);
  if (!imp) return false;

  Class add2Cls = isClassMethod ? object_getClass(cls) : cls;
  IMP oldIMP = class_replaceMethod(add2Cls, sel, imp, encoding);

  if (oldIMP) {
      size_t selLen = strlen(selName);
      char* selBuffer = (char*)alloca(selLen + 3); // 2 for OC prefix
      memcpy(selBuffer, "OC", 2); // add OC prefix
      memcpy(selBuffer+2, selName, selLen+1); // include \0 end
      sel = sel_getUid(selBuffer);
      if (!class_respondsToSelector(add2Cls, sel)){ // first override, set OC imp
          class_addMethod(add2Cls, sel, oldIMP, encoding);
      }
  }

  return true;
}

static void luaoc_push_lua_func(lua_State *L, Class cls, SEL sel, bool isClassMethod) {
  LUA_PUSH_STACK(L);

  lua_rawgetfield(L, LUA_REGISTRYINDEX, LOADED_CLASS_TABLE);

  const char* selName = sel_getName(sel);
  const char* indexName =
    isClassMethod ? kClassMethodIndex : kInstanceMethodIndex;

  {
    LUA_PUSH_STACK(L);
    while(cls) {
      if (lua_rawgetp(L, -1, cls) == LUA_TUSERDATA){
        lua_getuservalue(L, -1);
        if (lua_rawgetfield(L, -1, indexName) == LUA_TTABLE) {
          if (lua_rawgetfield(L, -1, selName) == LUA_TFUNCTION) { // found
            goto pushLuaFuncEnd;
          }
        }
      }
      LUA_POP_STACK(L, 0);
      cls = class_getSuperclass(cls);
    }
    lua_pushnil(L);
  }

pushLuaFuncEnd:
  LUA_POP_STACK(L, 1);
}

static void luaoc_set_lua_func(lua_State *L, int clsIndex, const char* name, bool isClassMethod) {
  LUA_PUSH_STACK(L);

  lua_getuservalue(L, clsIndex);
  const char* indexName = isClassMethod?kClassMethodIndex:kInstanceMethodIndex;
  if (lua_rawgetfield(L, -1, indexName) == LUA_TNIL){ // if nil, create one
    lua_newtable(L);
    lua_pushvalue(L, -1); // push a copy of table, ensure table at the top
    lua_rawsetfield(L, -4, indexName);
  }
  lua_pushvalue(L, LUA_START_INDEX(L)); // top is func
  lua_rawsetfield(L, -2, name); // table[name] = func

  LUA_POP_STACK(L, -1); // popup the func
}

int index_value_from_class(lua_State *L, Class cls, int keyIndex) {
  LUA_PUSH_STACK(L);

  lua_rawgetfield(L, LUA_REGISTRYINDEX, LOADED_CLASS_TABLE);
  keyIndex = lua_absindex(L, keyIndex);
  while(cls) {
    if (lua_rawgetp(L, -1, cls) == LUA_TUSERDATA){
      lua_getuservalue(L, -1);
      lua_pushvalue(L, keyIndex);
      if (lua_rawget(L, -2) != LUA_TNIL) {
        LUA_POP_STACK(L, 1);
        return 1;
      }
      lua_pop(L, 3); // pop lua_rawgetp, uservalue, rawget value
    }
    cls = class_getSuperclass(cls);
  }
  LUA_POP_STACK(L, 0);
  return 0;
}

static int __index(lua_State *L){
  Class* cls = (Class*)luaL_checkudata(L, 1, LUAOC_CLASS_METATABLE_NAME);

  lua_getuservalue(L, 1);
  lua_pushvalue(L, 2); // : ud key udv key
  if (lua_rawget(L, -2) == LUA_TNIL) {
    if (lua_type(L,2) == LUA_TSTRING) {
      // is nil and key is string , return try message wrapper
      SEL sel = luaoc_find_SEL_byname(*cls, lua_tostring(L, 2));
      if (sel) {
        luaoc_push_msg_send(L, sel);
      }
    }
    if (lua_isnil(L, -1)) { // still nil
      // when not a oc msg, try to find value in super
      index_value_from_class(L, class_getSuperclass(*cls), 2);
    }
  }

  return 1;
}

static int __newindex(lua_State *L){
  luaL_checkudata(L, 1, LUAOC_CLASS_METATABLE_NAME);

  lua_getuservalue(L, 1);
  lua_insert(L, 2);
  lua_rawset(L, 2);                         // udv[key] = value

  return 0;
}

/** define or override method
 *
 *  @param 1: cls
 *  @param 2: methodname, first char can be +- to distinguish class method and
 *            instance method. default instance method
 *  @param 3: lua_func, first param is Class or self, other param as you define.
 *            don't have SEL as second param like oc
 *  @param 4: encoding, optional, if nil, only override method or imp protocol
 *  @return   true if success
 */
static int __call(lua_State *L) {
  Class* cls = (Class*)luaL_checkudata(L, 1, LUAOC_CLASS_METATABLE_NAME);
  const char* name = luaL_checkstring(L, 2);
  luaL_checktype(L, 3, LUA_TFUNCTION);

  bool isClassMethod = false;
  if (*name == '+') {isClassMethod = true; ++name;}
  else if (*name == '-') {isClassMethod = false; ++name;}
  while(isspace(*name)) ++name; // skip prefix space

  const char* encoding;

  if ( lua_isnoneornil(L, 4) ) {
      // default retType and allParam type is @.
      lua_Debug ar;
      lua_pushvalue(L, 3);
      lua_getinfo(L, ">u", &ar);
      encoding = alloca( ar.nparams + 3 );
      memcpy((char*)encoding, "@@:", 3);
      if (ar.nparams > 1) {
          memset((char*)encoding + 3, '@', ar.nparams-1);
      }
      ((char*)encoding)[ar.nparams+2] = '\0';
  } else {
      luaoc_push_encoding_for_index(L, 4);
      lua_replace(L, 4);
      encoding = (char*)lua_tostring(L, 4);
  }

  if (override(*cls, name, isClassMethod, encoding) )
  {
    lua_pushvalue(L, 3);
    luaoc_set_lua_func(L, 1, name, isClassMethod);
    lua_pushboolean(L, true);
  } else {
    DLOG("[WARN] can't override method for name '%s'", name);
    lua_pushboolean(L, false);
  }

  return 1;
}

static const luaL_Reg metaMethods[] = {
  {"__index", __index},
  {"__newindex", __newindex},
  {"__call", __call},
  {NULL, NULL}
};

int luaopen_luaoc_class(lua_State *L) {
  luaL_newlib(L, ClassTableMethods);
  luaL_newlib(L, ClassTableMetaMethods);
  lua_setmetatable(L, -2);                          // : clsTable

  // class's meta table
  luaL_newmetatable(L, LUAOC_CLASS_METATABLE_NAME);
  luaL_setfuncs(L, metaMethods, 0);                 // + classMetaTable

  lua_pushstring(L, "__type");
  lua_pushinteger(L, luaoc_class_type);
  lua_rawset(L, -3);                                // classMetaTable.type = "class"

  // a new loaded table hold all class pointer to lua repr
  lua_newtable(L);
  lua_rawsetfield(L, LUA_REGISTRYINDEX, LOADED_CLASS_TABLE);

  lua_pop(L, 1);                                    // : clsTable

  #ifndef NO_USE_FFI
  if (!luaFuncDict){
    luaFuncDict = [[NSMutableDictionary alloc] init];
  }
  #endif

  return 1;
}

