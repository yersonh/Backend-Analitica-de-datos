import 'package:flutter_test/flutter_test.dart';
import 'package:sidfam_app/app_state.dart';
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
}
