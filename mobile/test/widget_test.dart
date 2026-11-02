import 'package:flutter_test/flutter_test.dart';
import 'package:sidfam_app/app_state.dart';
import 'package:sidfam_app/fleet_controller.dart';
import 'package:sidfam_app/util.dart';

void main() {
  test('normaliza la URL del servidor', () {
    expect(AppState.normalizeUrl(' 192.168.1.100:8000/ '), 'http://192.168.1.100:8000');
    expect(AppState.normalizeUrl('https://sidfam.up.railway.app'), 'https://sidfam.up.railway.app');
  });

  test('clave de estado igual que el panel web', () {
    expect(statusKey(null), 'sindatos');
    expect(statusKey({'has_any_data': true, 'status': 'alerta', 'risk_level': 'alto'}), 'alerta-alto');
    expect(statusKey({'has_any_data': true, 'status': 'alerta'}), 'alerta-medio');
    expect(statusKey({'has_any_data': true, 'status': 'vigilancia'}), 'vigilancia');
    expect(statusKey({'has_any_data': true, 'status': 'advertencia_sensor'}), 'advertencia_sensor');
    expect(statusKey({'has_any_data': true, 'status': 'normal'}), 'normal');
  });

  test('la vigilancia tiene su propio estilo, sin entrar a los conteos por riesgo', () {
    expect(riskStyle('vigilancia').label, 'Vigilancia');
    expect(kRisk.containsKey('vigilancia'), isFalse);
  });

  group('aviso de vigilancia de la flota', () {
    late FleetController fleet;
    late List<String> avisos;

    void estados(Map<String, String> porSesion) {
      fleet.drivers = [
        for (final e in porSesion.entries) {'session_id': e.key, 'estado': e.value},
      ];
      fleet.detectWatch();
    }

    setUp(() {
      avisos = [];
      fleet = FleetController(AppState())
        ..onWatch = (d) => avisos.addAll(d.map((x) => x['session_id'] as String));
    });

    test('avisa al pasar de normal a vigilancia, una sola vez', () {
      estados({'a': 'normal'});
      estados({'a': 'vigilancia'});
      estados({'a': 'vigilancia'});
      expect(avisos, ['a']);
    });

    test('un conductor que aparece en vigilancia también avisa', () {
      estados({'a': 'normal'});
      estados({'a': 'normal', 'b': 'vigilancia'});
      expect(avisos, ['b']);
    });

    test('no avisa de lo que ya estaba en la primera carga', () {
      estados({'a': 'vigilancia'});
      expect(avisos, isEmpty);
    });

    test('bajar de alerta a vigilancia no es un aviso nuevo', () {
      estados({'a': 'alerta-alto'});
      estados({'a': 'vigilancia'});
      expect(avisos, isEmpty);
    });

    test('si oscila no repite el aviso, pero otro conductor sí avisa', () {
      estados({'a': 'normal', 'b': 'normal'});
      estados({'a': 'vigilancia', 'b': 'normal'});
      estados({'a': 'normal', 'b': 'normal'});
      estados({'a': 'vigilancia', 'b': 'vigilancia'});
      expect(avisos, ['a', 'b']);
    });
  });
}
