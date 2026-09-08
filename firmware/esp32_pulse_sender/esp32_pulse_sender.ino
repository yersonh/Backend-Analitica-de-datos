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

const unsigned long PULSE_SEND_INTERVAL_MS = 2000;  // cada 2s (ajustable)

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

void sendPulseReading(float bpm) {
  HTTPClient http;
  String url = String(SERVER_HOST) + "/pulso";
  http.begin(url);
  http.addHeader("Content-Type", "application/x-www-form-urlencoded");

  String body = "bpm=" + String(bpm, 1) + "&session_id=" + String(SESSION_ID);
  int httpCode = http.POST(body);

  if (httpCode > 0) {
    Serial.printf("POST /pulso -> %d\n", httpCode);
    Serial.println(http.getString());
  } else {
    Serial.printf("Error en POST /pulso: %s\n", http.errorToString(httpCode).c_str());
  }
  http.end();
}

void setup() {
  Serial.begin(115200);
  Wire.begin();
  setupSensor();
  connectWiFi();
}

void loop() {
  updatePulseReading();

  if (millis() - lastSendTime >= PULSE_SEND_INTERVAL_MS) {
    lastSendTime = millis();
    if (beatAvg > 0 && WiFi.status() == WL_CONNECTED) {
      sendPulseReading(beatAvg);
    }
  }
}
