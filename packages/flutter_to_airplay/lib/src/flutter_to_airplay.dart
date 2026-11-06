import 'package:flutter/painting.dart';

class FlutterToAirplay {
  static const String name = 'flutter_to_airplay';

  static Map<String, dynamic> colorToParams(Color color) {
    return {
      'red': color.r,
      'green': color.g,
      'blue': color.b,
      'alpha': color.a,
    };
  }
}
