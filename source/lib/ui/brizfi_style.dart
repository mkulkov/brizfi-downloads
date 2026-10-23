import 'package:flutter/material.dart';

Duration brizfiMotionDuration(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context)
    ? Duration.zero
    : const Duration(milliseconds: 180);

/// Keeps the top edge anchored while content changes height.
class BrizfiMotionSize extends StatelessWidget {
  const BrizfiMotionSize({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return AnimatedSize(
      duration: brizfiMotionDuration(context),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: child,
    );
  }
}

/// Fades newly inserted content once; ordinary rebuilds retain its state.
class BrizfiFadeIn extends StatelessWidget {
  const BrizfiFadeIn({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: brizfiMotionDuration(context),
      curve: Curves.easeOut,
      builder: (context, opacity, child) =>
          Opacity(opacity: opacity, alwaysIncludeSemantics: true, child: child),
      child: child,
    );
  }
}

/// Creates the shared Material 3 theme for BRIZFI.
ThemeData brizfiTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  // Flat representative colors sampled from the approved light/dark sketch.
  final primary = isDark ? const Color(0xFF8FD9D3) : const Color(0xFF247575);
  final onPrimary = isDark ? const Color(0xFF102735) : const Color(0xFFFFFFFF);
  final background = isDark ? const Color(0xFF162631) : const Color(0xFFFBF8F2);
  final surface = isDark ? const Color(0xFF23343F) : const Color(0xFFF7F5F0);
  final onSurface = isDark ? const Color(0xFFFBF8F2) : const Color(0xFF102735);
  final muted = isDark ? const Color(0xFFC1CBD0) : const Color(0xFF4C5963);
  final softOutline = isDark
      ? const Color(0xFF3F505B)
      : const Color(0xFFDEDDD7);
  final neutral = isDark ? const Color(0xFF364550) : const Color(0xFFEEEBE5);
  final selected = isDark ? const Color(0xFF92DAD4) : const Color(0xFF185B5D);
  final outline = isDark ? const Color(0xFF71878D) : const Color(0xFF788582);

  final colorScheme =
      ColorScheme.fromSeed(seedColor: primary, brightness: brightness).copyWith(
        primary: primary,
        onPrimary: onPrimary,
        secondary: selected,
        onSecondary: onPrimary,
        tertiary: isDark ? primary : const Color(0xFF0C495B),
        surface: surface,
        onSurface: onSurface,
        onSurfaceVariant: muted,
        surfaceContainerHighest: neutral,
        outline: outline,
        outlineVariant: softOutline,
        error: isDark ? const Color(0xFFFFB4AB) : const Color(0xFFBA1A1A),
        onError: isDark ? const Color(0xFF690005) : const Color(0xFFFFFFFF),
      );

  final buttonShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(16),
  );
  final buttonStyle = ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(0, 56)),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 24, vertical: 16),
    ),
    shape: WidgetStatePropertyAll(buttonShape),
  );
  final filledStyle = buttonStyle.copyWith(
    overlayColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) return Colors.transparent;
      if (states.contains(WidgetState.pressed) ||
          states.contains(WidgetState.hovered) ||
          states.contains(WidgetState.focused)) {
        return (isDark ? Colors.white : Colors.black).withValues(alpha: .08);
      }
      return Colors.transparent;
    }),
    backgroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.disabled) ? neutral : primary,
    ),
    foregroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.disabled) ? muted : onPrimary,
    ),
  );
  final outlinedStyle = buttonStyle.copyWith(
    foregroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.disabled) ? muted : selected,
    ),
    side: WidgetStateProperty.resolveWith(
      (states) => BorderSide(
        color: states.contains(WidgetState.disabled) ? outline : selected,
        width: 1.5,
      ),
    ),
  );

  return ThemeData(
    useMaterial3: true,
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    brightness: brightness,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: background,
    appBarTheme: AppBarTheme(
      backgroundColor: background,
      foregroundColor: onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      titleTextStyle:
          ThemeData(brightness: brightness, colorScheme: colorScheme)
              .textTheme
              .titleLarge
              ?.copyWith(color: onSurface, fontWeight: FontWeight.w700),
    ),
    filledButtonTheme: FilledButtonThemeData(style: filledStyle),
    elevatedButtonTheme: ElevatedButtonThemeData(style: filledStyle),
    outlinedButtonTheme: OutlinedButtonThemeData(style: outlinedStyle),
    textButtonTheme: TextButtonThemeData(style: buttonStyle),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(buttonShape),
        side: WidgetStatePropertyAll(BorderSide(color: softOutline)),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? selected : neutral,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? onPrimary
              : states.contains(WidgetState.disabled)
              ? muted
              : onSurface,
        ),
      ),
    ),
  );
}

/// Keeps the mobile screen's header, form and footer in one aligned column
/// when a desktop window is wider than the content.
class BrizfiWindowFrame extends StatelessWidget {
  const BrizfiWindowFrame({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).scaffoldBackgroundColor,
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: child,
      ),
    ),
  );
}

/// A lightly outlined surface for grouping related content.
class BrizfiPanel extends StatelessWidget {
  const BrizfiPanel({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colors.outlineVariant),
      ),
      elevation: 0,
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );
  }
}

/// Displays one selected book with its current status and remove action.
class BrizfiBookCard extends StatelessWidget {
  const BrizfiBookCard({
    required this.title,
    required this.status,
    required this.removeLabel,
    required this.onRemove,
    super.key,
  });

  final String title;
  final Widget status;
  final String removeLabel;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return BrizfiPanel(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(
            child: Icon(
              Icons.menu_book_outlined,
              size: 32,
              color: Theme.of(context).brightness == Brightness.dark
                  ? colors.primary
                  : colors.onSurface,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    softWrap: true,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  BrizfiMotionSize(child: status),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            style: IconButton.styleFrom(
              backgroundColor: colors.surfaceContainerHighest,
              foregroundColor: colors.onSurfaceVariant,
            ),
            tooltip: removeLabel,
            onPressed: onRemove,
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }
}

/// BRIZFI's book mark and wordmark, suitable for an app bar title.
class BrizfiBrand extends StatelessWidget {
  const BrizfiBrand({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (MediaQuery.textScalerOf(context).scale(22) > 36) {
      return Semantics(
        label: 'BRIZFI',
        child: ExcludeSemantics(
          child: Icon(
            Icons.menu_book_rounded,
            size: 32,
            color: colors.secondary,
          ),
        ),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ExcludeSemantics(
          child: Icon(
            Icons.menu_book_rounded,
            size: 28,
            color: colors.secondary,
          ),
        ),
        const SizedBox(width: 10),
        Text(
          'BRIZFI',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            color: colors.onSurface,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
          ),
        ),
      ],
    );
  }
}
