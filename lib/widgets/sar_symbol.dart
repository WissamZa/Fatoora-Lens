import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../l10n.dart';

/// Renders the official Saudi Riyal symbol SVG from assets/icons/sar_symbol.svg
class SarSymbol extends StatelessWidget {
  const SarSymbol({
    this.size = 14,
    this.color,
    super.key,
  });

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ??
        IconTheme.of(context).color ??
        DefaultTextStyle.of(context).style.color ??
        Theme.of(context).colorScheme.primary;

    return SvgPicture.asset(
      'assets/icons/sar_symbol.svg',
      width: size,
      height: size,
      fit: BoxFit.contain,
      colorFilter: ColorFilter.mode(effectiveColor, BlendMode.srcIn),
    );
  }
}

/// Formats and displays an amount with the SAR symbol attached consistently.
class SarAmount extends StatelessWidget {
  const SarAmount({
    required this.amount,
    this.style,
    this.symbolSize,
    this.symbolColor,
    this.spacing = 3.5,
    this.mainAxisSize = MainAxisSize.min,
    super.key,
  });

  final double amount;
  final TextStyle? style;
  final double? symbolSize;
  final Color? symbolColor;
  final double spacing;
  final MainAxisSize mainAxisSize;

  @override
  Widget build(BuildContext context) {
    final defaultStyle = DefaultTextStyle.of(context).style;
    final effectiveStyle = style ?? defaultStyle;
    final fontSize = effectiveStyle.fontSize ?? 14.0;
    final effectiveSymbolSize = symbolSize ?? (fontSize * 0.85).clamp(11.0, 36.0);
    final effectiveSymbolColor = symbolColor ?? effectiveStyle.color;

    return Row(
      mainAxisSize: mainAxisSize,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          amount.toStringAsFixed(2),
          style: effectiveStyle,
        ),
        SizedBox(width: spacing),
        SarSymbol(
          size: effectiveSymbolSize,
          color: effectiveSymbolColor,
        ),
      ],
    );
  }
}

/// A compact, elegant badge to display the VAT tax amount.
class SarTaxBadge extends StatelessWidget {
  const SarTaxBadge({
    required this.amount,
    this.showLabel = true,
    this.customLabel,
    this.compact = false,
    super.key,
  });

  final double amount;
  final bool showLabel;
  final String? customLabel;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final label = customLabel ?? tr(context, 'tax');

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 8,
        vertical: compact ? 2 : 3.5,
      ),
      decoration: BoxDecoration(
        color: isDark
            ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6)
            : theme.colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: isDark ? 0.25 : 0.18),
          width: 0.8,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (showLabel) ...[
            Text(
              '$label: ',
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.primary,
                fontSize: compact ? 10.5 : 11.5,
              ),
            ),
          ],
          SarAmount(
            amount: amount,
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: compact ? 11 : 12,
            ),
            symbolSize: compact ? 9.5 : 10.5,
            symbolColor: theme.colorScheme.primary,
            spacing: 2,
          ),
        ],
      ),
    );
  }
}
