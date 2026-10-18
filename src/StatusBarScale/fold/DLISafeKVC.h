// DLISafeKVC.h —— 运行时安全读取（本项目相对上游的唯一基础设施改动之一）。
//
// 背景（iOS 16.5.1 实测）：上游 DuoStatusRing 用 valueForKey: 直读系统私有成员，
// 目标环境是 iOS 26；本机 16.5.1 上 `_cachedLayoutDidChangeUserInfo`、`_settings`、
// `*InterfaceElementTransitionSettings` 都不存在，KVC 会抛 NSInvalidArgumentException。
// 每次状态栏布局都抛一次异常的代价不可接受（异常构造/栈展开在 SpringBoard 主线程上
// 是毫秒级尖峰），因此这里先查 ivar（且只接受对象类型编码 @，避免 object_getIvar
// 误用破坏堆），再查 getter，最后才走 KVC。
#pragma once
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

FOUNDATION_EXTERN id DLISafeValue(id object, NSString *key);
