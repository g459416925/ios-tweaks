// SBDFold.h —— 把 DuoStatusRing（MIT，OwnGoal Studio）移植进 StatusBarScale 的桥接层。
//
// 职责：
//   1. 安装折叠所需的 5 个 STUIStatusBar hook（带类型编码校验，不匹配就跳过并记日志）；
//   2. 在 iOS 16 上订阅 SBSystemApertureLayoutDidChangeNotification（iOS 17+ 仍走布局 hook）；
//   3. 提供统一日志出口（写入 sbs_log.txt，前缀 [fold]）与开关。
//
// 与上游的差异全部集中在本文件 + DLIApertureObserver / DLISafeKVC：
//   · 上游用自带 TW_HOOK 表 + constructor 安装；本插件已有统一安装入口，改由 sbd_install() 安装。
//   · 上游主 hook `SBSystemApertureViewController -_postLayoutDidChangeNotificationIfNecessary`
//     在 iOS 16.5.1 不存在（dyld 缓存实证），改为通知订阅。
//   · 上游读 `_cachedLayoutDidChangeUserInfo`；iOS 16 无此 ivar，改读通知 userInfo 的
//     SBSystemApertureFramesKey / SBSystemApertureVisibleElementIdentifiersKey。
#pragma once
#import <Foundation/Foundation.h>

// 折叠功能总开关（编译期）。出问题时置 NO 重编译即可完全停用，状态栏缩放不受影响。
#ifndef SBD_FOLD_ENABLED
#define SBD_FOLD_ENABLED 1
#endif

FOUNDATION_EXTERN void SBDFoldLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
// 安装折叠模块；类未就绪时内部重试。可重复调用。
FOUNDATION_EXTERN void SBDFoldInstall(void);
// 供状态栏缩放侧判断折叠是否处于活动状态（避免将来做互斥时无处查询）。
FOUNDATION_EXTERN BOOL SBDFoldIsActive(void);
