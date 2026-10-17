// Paleta y tema oscuro, equivalentes a los del panel web.

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
    scaffoldBackgroundColor: C.bg,
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
      backgroundColor: C.bg,
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
    navigationBarTheme: const NavigationBarThemeData(backgroundColor: C.card, indicatorColor: Color(0x3338BDF8)),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating, backgroundColor: C.cardHi),
    textTheme: base.textTheme.apply(bodyColor: C.text, displayColor: C.text),
  );
}
