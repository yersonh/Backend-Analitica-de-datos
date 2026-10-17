// Paleta y tema oscuro, equivalentes a los del panel web.

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

class C {
  static const bg = Color(0xFF030712);
  static const card = Color(0xFF0B1324);
  static const cardHi = Color(0xFF111C33);
  static const border = Color(0x2694B2EB);
  static const text = Color(0xFFE6EDF7);
  static const muted = Color(0xFF9FB0D0);

  static const verde = Color(0xFF4ADE80);
  static const esmeralda = Color(0xFF34D399);
  static const ambar = Color(0xFFFBBF24);
  static const naranja = Color(0xFFFB923C);
  static const rojo = Color(0xFFFB7185);
  static const violeta = Color(0xFFC084FC);
  static const cyan = Color(0xFF38BDF8);
  static const azul = Color(0xFF60A5FA);
  static const gris = Color(0xFF94A3B8);

  static Color role(String? role) => switch (role) {
    'administrador' => violeta,
    'supervisor' => cyan,
    'conductor' => verde,
    _ => gris,
  };
}

ThemeData buildTheme() {
  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    // transparente: el fondo aurora (widgets/brand.dart) se pinta detrás de todas las pantallas
    scaffoldBackgroundColor: Colors.transparent,
    colorScheme: const ColorScheme.dark(
      primary: C.cyan,
      secondary: C.violeta,
      surface: C.card,
      error: C.rojo,
      onSurface: C.text,
    ),
  );
  return base.copyWith(
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: C.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: C.cardHi,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: C.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: C.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: C.cyan),
      ),
      labelStyle: const TextStyle(color: C.muted),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: C.card.withValues(alpha: 0.82),
      indicatorColor: const Color(0x3338BDF8),
      indicatorShape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => TextStyle(
          fontSize: 12,
          fontWeight: s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
          color: s.contains(WidgetState.selected) ? C.text : C.muted,
        ),
      ),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      },
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: C.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      showDragHandle: true,
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating, backgroundColor: C.cardHi),
    textTheme: base.textTheme.apply(bodyColor: C.text, displayColor: C.text),
  );
}

/// Fondo de tarjeta "vidrio" sobre la aurora: gradiente translúcido, borde
/// fino y sombra; con [accent] el borde y el halo toman ese color.
BoxDecoration glassDecoration({Color? accent, double radius = 20}) => BoxDecoration(
  gradient: LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [C.cardHi.withValues(alpha: 0.86), C.card.withValues(alpha: 0.74)],
  ),
  borderRadius: BorderRadius.circular(radius),
  border: Border.all(color: accent?.withValues(alpha: 0.5) ?? C.border),
  // sombra solo con acento: una sombra difusa en cada tarjeta es cara de dibujar
  boxShadow: accent == null
      ? null
      : [
          BoxShadow(
            color: accent.withValues(alpha: 0.22),
            blurRadius: 20,
            offset: const Offset(0, 10),
            spreadRadius: -8,
          ),
        ],
);
