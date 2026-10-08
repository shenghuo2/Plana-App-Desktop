import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/app_info.dart';
import 'core/auth/auth_mode.dart';
import 'core/auth/credential_store.dart';
import 'core/auth/secure_storage.dart';
import 'core/platform/clipboard_image.dart';
import 'core/platform/desktop.dart';
import 'core/store/app_stores.dart';
import 'core/store/gen_settings.dart';
import 'core/store/storage_lifecycle.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/app_text_scale.dart';
import 'core/theme/theme_settings.dart';
import 'core/ui/input_focus_guard.dart';
import 'core/ui/image_drop.dart';
import 'core/ui/nav_bar_guard.dart';
import 'features/import/desktop_image_drop.dart';
import 'features/generate/widgets/common.dart';
import 'features/onboarding/welcome_page.dart';
import 'features/profile/account_page.dart';
import 'features/shell/app_shell.dart';
import 'core/util/haptics.dart';
import 'features/editor/data/local_tag_db.dart';
import 'features/editor/editor_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isMacOS &&
      Platform.environment[kMacOsKeychainSmokeTestEnvironment] == '1') {
    try {
      await runMacOsKeychainSmokeTest();
      stdout.writeln('macOS Keychain smoke test passed.');
      exit(0);
    } catch (error, stackTrace) {
      stderr
        ..writeln('macOS Keychain smoke test failed: $error')
        ..writeln(stackTrace);
      exit(1);
    }
  }
  // 剪贴板那条原生通道同理:没注册上时构建和启动都正常,只有用户按 ⌘V 才发现。
  if (Platform.isMacOS &&
      Platform.environment[kMacOsClipboardSmokeTestEnvironment] == '1') {
    try {
      await runMacOsClipboardSmokeTest();
      stdout.writeln('macOS clipboard smoke test passed.');
      exit(0);
    } catch (error, stackTrace) {
      stderr
        ..writeln('macOS clipboard smoke test failed: $error')
        ..writeln(stackTrace);
      exit(1);
    }
  }
  // 离线词库索引与存档并行读:它不压缩存、引擎直接 mmap,几毫秒就好。装好后
  // 注音 / 热度反查从第一帧起就是同步可用的,不再有开机「灌注」这一步。
  final tagDb = LocalTagDb();
  final tagDbReady = tagDb.install();
  // 启动装载持久化状态(工作台存档 + 图库索引 + 设置;失败按首启空档降级)。
  // 外观预读(首帧不闪色)现在直接取内存态 —— 设置已随 AppStores 一次读全,
  // 不再需要第二笔 I/O,也不必再解一次 Keystore。
  final stores = await AppStores.open();
  // 凭据出口:桌面沿用平台加密存储;Android 才启用 Keystore 恢复退路。
  // 要排在 AppStores 之后,恢复判定用得上已迁出的接入方式。
  final creds = await CredentialStore.open(stores.prefs);
  await tagDbReady;
  final themeInit = loadThemeSettings(stores.prefs);
  final editorSessions = EditorSessions();
  runApp(
    ProviderScope(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        editorSessionsProvider.overrideWithValue(editorSessions),
        secureStorageProvider.overrideWithValue(creds),
        themeInitProvider.overrideWithValue(themeInit),
        localTagDbProvider.overrideWithValue(tagDb),
      ],
      child: const PlanaApp(),
    ),
  );
  // 注册即挂到 binding 观察者列表(强引用,不会被 GC):
  // 退后台/失焦即刻冲刷防抖存档，桌面正常退出还会等待所有存储写入完成。
  createStorageLifecycleListener(
    stores,
    beforeFlush: editorSessions.flushPending,
  );
  stores.postBootMaintenance(); // 选图器缓存清扫 + blob GC(延迟后台跑)
}

/// 弹层关掉后不把键盘顶出来(见 [InputFocusGuard])。放在外面:换主题时 MaterialApp
/// 会重建,观察者得是同一个。
final _inputFocusGuard = InputFocusGuard();

class PlanaApp extends ConsumerWidget {
  const PlanaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ts = ref.watch(themeSettingsProvider);
    final desktop = ref.watch(desktopModeProvider);
    ThemeData adapt(ThemeData theme) => !desktop
        ? theme
        : theme.copyWith(
            textTheme: theme.textTheme.apply(
              fontFamily: Platform.isMacOS
                  ? '.AppleSystemUIFont'
                  : 'Microsoft YaHei',
              fontFamilyFallback: Platform.isMacOS
                  ? const ['PingFang SC']
                  : const ['Segoe UI'],
            ),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            bottomSheetTheme: theme.bottomSheetTheme.copyWith(
              constraints: const BoxConstraints(maxWidth: 720),
            ),
            dialogTheme: theme.dialogTheme.copyWith(
              constraints: const BoxConstraints(maxWidth: 760),
            ),
          );
    // 桌面关闭触感调用;移动端将触感设置同步到全局出口。
    Haptics.enabled = !desktop && ts.haptics;
    return MaterialApp(
      title: kAppName,
      debugShowCheckedModeBanner: false,
      theme: adapt(AppTheme.light(ts.seed.color)),
      darkTheme: adapt(AppTheme.dark(ts.seed.color)),
      themeMode: ts.mode,
      navigatorObservers: [_inputFocusGuard],
      builder: (context, child) => desktop
          ? AppTextScale(
              factor: ts.textScale,
              child: DesktopImageDropHost(child: child!),
            )
          : NavBarGuard(child: child!),
      home: const _AuthGate(),
    );
  }
}

/// 启动 gate:桌面端直接进入工作台;移动端欢迎流程未完成或未选接入方式时
/// 进入欢迎页。首帧 loading 时垫占位,避免闪主界面。
class _AuthGate extends ConsumerWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(desktopModeProvider)) {
      return const DesktopImportRegion(
        acceptInternal: false,
        child: AppShell(),
      );
    }
    final mode = ref.watch(authModeProvider);
    final gs = ref.watch(genSettingsProvider);
    if (mode.isLoading || gs.isLoading) return const _SplashHold();
    // 读失败一律按首启处理:宁可多走一次欢迎,也不让人卡在空界面
    final primed = gs.value?.notifyPrimed ?? false;
    if (!primed || mode.value == null) return const WelcomePage();
    return const _CredentialLostHint(child: AppShell());
  }
}

/// 加密存储这次启动被系统清过(见 [CredentialStore])时,进主界面提示一次。
class _CredentialLostHint extends ConsumerStatefulWidget {
  const _CredentialLostHint({required this.child});

  final Widget child;

  @override
  ConsumerState<_CredentialLostHint> createState() =>
      _CredentialLostHintState();
}

class _CredentialLostHintState extends ConsumerState<_CredentialLostHint> {
  @override
  void initState() {
    super.initState();
    final creds = ref.read(secureStorageProvider);
    if (creds is! CredentialStore || !creds.takeLostNotice()) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      hintSnack(
        context,
        '已存的 Key 被系统清掉了,重新添加后不会再丢',
        icon: Icons.key_off_outlined,
        actionLabel: '去添加',
        onAction: () {
          if (mounted) {
            Navigator.of(context).push(sharedAxisRoute(const AccountPage()));
          }
        },
      );
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _SplashHold extends StatelessWidget {
  const _SplashHold();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Icon(
          Icons.auto_awesome,
          size: 40,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
