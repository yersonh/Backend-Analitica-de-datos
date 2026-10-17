/*
  SIDFAM - ESP32 (normal): lectura de pulso y envío al backend
  ---------------------------------------------------------------
  Envía el BPM calculado cada PULSE_INTERVAL_MS al endpoint
  POST /pulso del backend, como application/x-www-form-urlencoded.

  Este ejemplo asume un sensor MAX30102/MAX30105 (I2C) con la
  librería "MAX30105" de SparkFun + su algoritmo de cálculo de BPM.
  Si el sensor final es otro (p. ej. un pulsioxímetro genérico
  analógico), reemplazar SOLO la sección "Lectura del sensor" —
  el resto del flujo (WiFi + envío HTTP) no cambia.

  Librerías necesarias (Library Manager de Arduino IDE):
    - SparkFun MAX3010x Pulse and Proximity Sensor Library

  Buzzer (activo, en BUZZER_PIN): la respuesta de /pulso trae "buzzer": true
  mientras el sistema confirma fatiga o mientras un supervisor lo activó desde
  la app. Suena intermitente y se apaga solo si deja de llegar respuesta
  (BUZZER_SAFETY_MS), para que nunca quede pitando sin control.
*/

#include <WiFi.h>
#include <HTTPClient.h>
#include <Wire.h>
#include "MAX30105.h"
#include "heartRate.h"

// ---------- Configuración de red ----------
const char* WIFI_SSID     = "TU_RED_WIFI";
const char* WIFI_PASSWORD = "TU_PASSWORD";
const char* SERVER_HOST   = "http://192.168.1.100:8000";  // IP del backend en la red local
const char* SESSION_ID    = "default";
// Clave del dispositivo: el mismo valor que DEVICE_API_KEY en el backend.
// Vacía ("") si el backend no la exige (desarrollo local).
const char* DEVICE_API_KEY = "";

const unsigned long PULSE_SEND_INTERVAL_MS = 2000;  // cada 2s (ajustable)

// ---------- Buzzer ----------
const int BUZZER_PIN = 25;                     // buzzer ACTIVO: HIGH = suena
const unsigned long BUZZER_ON_MS = 300;        // patrón intermitente: 300 ms sonando...
const unsigned long BUZZER_OFF_MS = 200;       // ...200 ms en silencio
const unsigned long BUZZER_SAFETY_MS = 5000;   // sin confirmación del servidor en 5 s -> se apaga

bool buzzerWanted = false;          // lo que pidió el servidor en la última respuesta
unsigned long buzzerConfirmedAt = 0;

MAX30105 particleSensor;

const byte RATE_SIZE = 4;
byte rates[RATE_SIZE];
byte rateSpot = 0;
long lastBeat = 0;
float beatsPerMinute;
int beatAvg;

unsigned long lastSendTime = 0;

void connectWiFi() {
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  Serial.print("Conectando a WiFi");
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }
  Serial.println();
  Serial.print("Conectado. IP: ");
  Serial.println(WiFi.localIP());
}

void setupSensor() {
  if (!particleSensor.begin(Wire, I2C_SPEED_FAST)) {
    Serial.println("Sensor MAX3010x no encontrado. Revisar conexiones.");
    while (true) delay(1000);
  }
  particleSensor.setup();
  particleSensor.setPulseAmplitudeRed(0x0A);
  particleSensor.setPulseAmplitudeGreen(0);
}

// Lectura del sensor: actualiza beatAvg cada vez que detecta un latido.
void updatePulseReading() {
  long irValue = particleSensor.getIR();

  if (checkForBeat(irValue)) {
    long delta = millis() - lastBeat;
    lastBeat = millis();

    beatsPerMinute = 60.0 / (delta / 1000.0);

    if (beatsPerMinute > 20 && beatsPerMinute < 255) {
      rates[rateSpot++] = (byte)beatsPerMinute;
      rateSpot %= RATE_SIZE;

      int total = 0;
      for (byte i = 0; i < RATE_SIZE; i++) total += rates[i];
      beatAvg = total / RATE_SIZE;
    }
  }
}

// Patrón intermitente sin bloquear el loop (la lectura del sensor sigue corriendo).
void updateBuzzer() {
  bool active = buzzerWanted && (millis() - buzzerConfirmedAt < BUZZER_SAFETY_MS);
  if (!active) {
    digitalWrite(BUZZER_PIN, LOW);
    return;
  }
  unsigned long phase = millis() % (BUZZER_ON_MS + BUZZER_OFF_MS);
  digitalWrite(BUZZER_PIN, phase < BUZZER_ON_MS ? HIGH : LOW);
}

void sendPulseReading(float bpm) {
  HTTPClient http;
  String url = String(SERVER_HOST) + "/pulso";
  http.begin(url);
  http.addHeader("Content-Type", "application/x-www-form-urlencoded");
  if (strlen(DEVICE_API_KEY) > 0) {
    http.addHeader("X-Device-Key", DEVICE_API_KEY);
  }

  String form = "bpm=" + String(bpm, 1) + "&session_id=" + String(SESSION_ID);
  int httpCode = http.POST(form);

  if (httpCode > 0) {
    String body = http.getString();
    Serial.printf("POST /pulso -> %d\n", httpCode);
    Serial.println(body);
    if (httpCode == 200) {
      // JSON simple: basta buscar el campo, sin librería extra
      buzzerWanted = body.indexOf("\"buzzer\":true") >= 0 || body.indexOf("\"buzzer\": true") >= 0;
      buzzerConfirmedAt = millis();
    }
  } else {
    Serial.printf("Error en POST /pulso: %s\n", http.errorToString(httpCode).c_str());
  }
  http.end();
}

void setup() {
  Serial.begin(115200);
  pinMode(BUZZER_PIN, OUTPUT);
  digitalWrite(BUZZER_PIN, LOW);
  Wire.begin();
  setupSensor();
  connectWiFi();
}

void loop() {
  updatePulseReading();
  updateBuzzer();

  if (millis() - lastSendTime >= PULSE_SEND_INTERVAL_MS) {
    lastSendTime = millis();
    if (beatAvg > 0 && WiFi.status() == WL_CONNECTED) {
      sendPulseReading(beatAvg);
    }
  }
}
