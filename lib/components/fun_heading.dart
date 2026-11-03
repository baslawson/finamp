import 'package:finamp/gen/fonts.gen.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:flutter/material.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

/// The rounded display font headings use. Bundled, so it works offline; other scripts fall back to the system font.
const headingFontFamily = FontFamily.outfit;

/// The Hive box (and key) the app's settings live in.
const _settingsBox = "FinampSettings";

/// Gives a theme's headings the display font, heavier weights and tighter spacing so titles stand out. Body text,
/// list items and labels keep the normal font so long lists stay easy to read.
ThemeData withBoldHeadings(ThemeData theme) {
  final text = theme.textTheme;
  TextStyle? heading(TextStyle? style, FontWeight weight, double spacing, {double? size}) => style?.copyWith(
    fontFamily: headingFontFamily,
    fontWeight: weight,
    letterSpacing: spacing,
    fontSize: size ?? style.fontSize,
  );

  final textTheme = text.copyWith(
    displayLarge: heading(text.displayLarge, FontWeight.w900, -1.5),
    displayMedium: heading(text.displayMedium, FontWeight.w900, -1.0),
    displaySmall: heading(text.displaySmall, FontWeight.w900, -0.8),
    headlineLarge: heading(text.headlineLarge, FontWeight.w800, -0.6),
    headlineMedium: heading(text.headlineMedium, FontWeight.w800, -0.5),
    headlineSmall: heading(text.headlineSmall, FontWeight.w800, -0.4),
    titleLarge: heading(text.titleLarge, FontWeight.w800, -0.3, size: 23),
  );
  return theme.copyWith(
    textTheme: textTheme,
    chipTheme: theme.chipTheme.copyWith(shape: const StadiumBorder()),
  );
}

/// The style for section titles such as Home's "Recently played": the display font, bold, a little bigger than
/// list text.
TextStyle? sectionHeadingStyle(BuildContext context) => TextTheme.of(
  context,
).titleMedium?.copyWith(fontFamily: headingFontFamily, fontWeight: FontWeight.w800, fontSize: 19, letterSpacing: -0.2);

/// A heading in the accent colours, with an optional icon badge, that fades and slides in. High contrast mode gets
/// plain colours, and reduced motion skips the animation.
class GradientTitle extends StatelessWidget {
  const GradientTitle(this.text, {super.key, this.icon, this.style, this.maxLines = 1});

  final String text;
  final IconData? icon;

  /// Defaults to the theme's large title.
  final TextStyle? style;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    // Follows the app's high contrast setting as it changes. Without settings (such as in tests), only the system's.
    if (!Hive.isBoxOpen(_settingsBox)) return _title(context, appHighContrast: false);
    return ValueListenableBuilder(
      valueListenable: FinampSettingsHelper.finampSettingsListener,
      builder: (context, box, _) =>
          _title(context, appHighContrast: box.get(_settingsBox)?.useHighContrastColors ?? false),
    );
  }

  Widget _title(BuildContext context, {required bool appHighContrast}) {
    final scheme = ColorScheme.of(context);
    final plain = appHighContrast || MediaQuery.highContrastOf(context);
    final gradient = LinearGradient(colors: [scheme.primary, scheme.tertiary]);
    final textStyle = (style ?? TextTheme.of(context).titleLarge)?.copyWith(color: plain ? scheme.onSurface : null);

    Widget title = Text(text, style: textStyle, maxLines: maxLines, overflow: TextOverflow.ellipsis);
    if (!plain) {
      title = ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (bounds) => gradient.createShader(Offset.zero & bounds.size),
        child: title,
      );
    }
    if (icon != null) {
      title = Row(
        spacing: 10.0,
        children: [
          Container(
            padding: const EdgeInsets.all(6.0),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10.0),
              gradient: plain ? null : gradient,
              color: plain ? scheme.primary : null,
            ),
            child: Icon(icon, size: 20.0, color: scheme.onPrimary),
          ),
          Flexible(child: title),
        ],
      );
    }
    return HeadingEntrance(child: title);
  }
}

/// Fades and slides its child up into place once, unless the system asks for reduced motion.
class HeadingEntrance extends StatelessWidget {
  const HeadingEntrance({super.key, required this.child});

  static const duration = Duration(milliseconds: 220);

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: duration,
      curve: Curves.easeOutCubic,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(offset: Offset(0, (1 - value) * 8), child: child),
      ),
      child: child,
    );
  }
}

/// Gives a chip a small pop when it's selected, unless the system asks for reduced motion.
class SelectionPop extends StatelessWidget {
  const SelectionPop({super.key, required this.selected, required this.child});

  final bool selected;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedScale(
    scale: selected ? 1.06 : 1.0,
    duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 180),
    curve: Curves.easeOutBack,
    child: child,
  );
}
