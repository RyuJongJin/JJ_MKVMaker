import 'package:flutter/material.dart';

/// CapCut 참고 어두운 테마
class JjColors {
  static const bg = Color(0xFF141417);
  static const panel = Color(0xFF1E1E23);
  static const panelHigh = Color(0xFF28282F);
  static const border = Color(0xFF2E2E36);
  static const accent = Color(0xFF00C4CC); // CapCut 계열 청록
  static const text = Color(0xFFE8E8EC);
  static const textDim = Color(0xFF8E8E99);
  static const danger = Color(0xFFFF5C6C);
  static const success = Color(0xFF3DD68C);
}

ThemeData buildTheme() {
  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    colorScheme: const ColorScheme.dark(
      primary: JjColors.accent,
      secondary: JjColors.accent,
      surface: JjColors.panel,
      error: JjColors.danger,
    ),
    scaffoldBackgroundColor: JjColors.bg,
    fontFamily: 'Malgun Gothic',
  );
  return base.copyWith(
    // 66-2: 좌우로 밀어 화면을 옮길 때는 그 방향으로 미끄러지게 (그 밖의 화면 열기는 기본 전환)
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: NavSlideTransitionsBuilder(),
      TargetPlatform.windows: NavSlideTransitionsBuilder(),
      TargetPlatform.linux: NavSlideTransitionsBuilder(),
      TargetPlatform.macOS: NavSlideTransitionsBuilder(),
      TargetPlatform.iOS: NavSlideTransitionsBuilder(),
    }),
    dividerColor: JjColors.border,
    textTheme: base.textTheme.apply(
      bodyColor: JjColors.text,
      displayColor: JjColors.text,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: JjColors.accent,
        foregroundColor: Colors.black,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: JjColors.text,
        side: const BorderSide(color: JjColors.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    ),
  );
}

/// 66-2: 다음 화면으로 열리는 화면이 어느 쪽에서 들어올지 (+1 오른쪽에서 = 다음, −1 왼쪽에서 = 이전, 0 기본 전환).
/// 좌우로 밀기 · 이전 · 다음으로 옮길 때만 정하고, 화면이 열리면 (그 화면에 기억한 뒤) 0 으로 돌린다.
class NavSlide {
  static int pending = 0;
  static final _dir = Expando<int>('navSlide');
}

class NavSlideTransitionsBuilder extends PageTransitionsBuilder {
  const NavSlideTransitionsBuilder();

  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    // 처음 그릴 때의 방향을 그 화면에 기억한다 (전환 중에 다시 불려도 같은 방향)
    var dir = NavSlide._dir[route];
    if (dir == null) {
      dir = NavSlide._dir[route] = NavSlide.pending;
      NavSlide.pending = 0;
    }
    if (dir == 0) {
      return const PageTransitionsTheme().buildTransitions(route, context, animation, secondaryAnimation, child);
    }
    return SlideTransition(
      position: Tween(begin: Offset(dir.toDouble(), 0), end: Offset.zero)
          .animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: child,
    );
  }
}
