/*
  SIDFAM - ESP32-CAM: captura y envío de frames al backend
  ----------------------------------------------------------
  Envía un frame JPEG cada FRAME_INTERVAL_MS al endpoint POST /frame
  del backend FastAPI, como multipart/form-data (campo "file").

  Ajustar:
    - WIFI_SSID / WIFI_PASSWORD
    - SERVER_HOST (IP o dominio del backend)
    - Modelo de cámara (CAMERA_MODEL_AI_THINKER es el más común)

  Requiere las librerías: esp32-camera (incluida en el core de
  Arduino para ESP32) y HTTPClient.
*/

#include "esp_camera.h"
#include <WiFi.h>
#include <HTTPClient.h>

// ---------- Configuración de red ----------
const char* WIFI_SSID     = "TU_RED_WIFI";
const char* WIFI_PASSWORD = "TU_PASSWORD";
const char* SERVER_HOST   = "http://192.168.1.100:8000";  // IP del backend en la red local
const char* SESSION_ID    = "default";

const unsigned long FRAME_INTERVAL_MS = 1500;  // cada 1.5s (ajustable)

// ---------- Pines - modelo AI-Thinker ESP32-CAM ----------
#define PWDN_GPIO_NUM     32
#define RESET_GPIO_NUM    -1
#define XCLK_GPIO_NUM      0
#define SIOD_GPIO_NUM     26
#define SIOC_GPIO_NUM     27
#define Y9_GPIO_NUM       35
#define Y8_GPIO_NUM       34
#define Y7_GPIO_NUM       39
#define Y6_GPIO_NUM       36
#define Y5_GPIO_NUM       21
#define Y4_GPIO_NUM       19
#define Y3_GPIO_NUM       18
#define Y2_GPIO_NUM        5
#define VSYNC_GPIO_NUM    25
#define HREF_GPIO_NUM     23
#define PCLK_GPIO_NUM     22

unsigned long lastSendTime = 0;

void setupCamera() {
  camera_config_t config;
  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer   = LEDC_TIMER_0;
  config.pin_d0 = Y2_GPIO_NUM;
  config.pin_d1 = Y3_GPIO_NUM;
  config.pin_d2 = Y4_GPIO_NUM;
  config.pin_d3 = Y5_GPIO_NUM;
  config.pin_d4 = Y6_GPIO_NUM;
  config.pin_d5 = Y7_GPIO_NUM;
  config.pin_d6 = Y8_GPIO_NUM;
  config.pin_d7 = Y9_GPIO_NUM;
  config.pin_xclk = XCLK_GPIO_NUM;
  config.pin_pclk = PCLK_GPIO_NUM;
  config.pin_vsync = VSYNC_GPIO_NUM;
  config.pin_href = HREF_GPIO_NUM;
  config.pin_sscb_sda = SIOD_GPIO_NUM;
  config.pin_sscb_scl = SIOC_GPIO_NUM;
  config.pin_pwdn = PWDN_GPIO_NUM;
  config.pin_reset = RESET_GPIO_NUM;
  config.xclk_freq_hz = 20000000;
  config.pixel_format = PIXFORMAT_JPEG;

  // Resolución moderada: suficiente para landmarks faciales, sin saturar la red
  config.frame_size = FRAMESIZE_VGA;   // 640x480
  config.jpeg_quality = 12;            // menor = mejor calidad (10-20 razonable)
  config.fb_count = 1;

  esp_err_t err = esp_camera_init(&config);
  if (err != ESP_OK) {
    Serial.printf("Error al iniciar la camara: 0x%x\n", err);
    while (true) delay(1000);
  }
}

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

void sendFrame() {
  camera_fb_t* fb = esp_camera_fb_get();
  if (!fb) {
    Serial.println("Error al capturar frame");
    return;
  }

  HTTPClient http;
  String url = String(SERVER_HOST) + "/frame";
  http.begin(url);

  String boundary = "SIDFAMBoundary";
  http.addHeader("Content-Type", "multipart/form-data; boundary=" + boundary);

  String bodyStart =
      "--" + boundary + "\r\n" +
      "Content-Disposition: form-data; name=\"session_id\"\r\n\r\n" +
      String(SESSION_ID) + "\r\n" +
      "--" + boundary + "\r\n" +
      "Content-Disposition: form-data; name=\"file\"; filename=\"frame.jpg\"\r\n" +
      "Content-Type: image/jpeg\r\n\r\n";
  String bodyEnd = "\r\n--" + boundary + "--\r\n";

  size_t totalLen = bodyStart.length() + fb->len + bodyEnd.length();
  uint8_t* body = (uint8_t*)malloc(totalLen);
  if (!body) {
    Serial.println("Sin memoria suficiente para el request");
    esp_camera_fb_return(fb);
    http.end();
    return;
  }

  size_t offset = 0;
  memcpy(body + offset, bodyStart.c_str(), bodyStart.length()); offset += bodyStart.length();
  memcpy(body + offset, fb->buf, fb->len); offset += fb->len;
  memcpy(body + offset, bodyEnd.c_str(), bodyEnd.length()); offset += bodyEnd.length();

  int httpCode = http.POST(body, totalLen);
  if (httpCode > 0) {
    Serial.printf("POST /frame -> %d\n", httpCode);
    Serial.println(http.getString());
  } else {
    Serial.printf("Error en POST /frame: %s\n", http.errorToString(httpCode).c_str());
  }

  free(body);
  http.end();
  esp_camera_fb_return(fb);
}

void setup() {
  Serial.begin(115200);
  setupCamera();
  connectWiFi();
}

void loop() {
  if (millis() - lastSendTime >= FRAME_INTERVAL_MS) {
    lastSendTime = millis();
    if (WiFi.status() == WL_CONNECTED) {
      sendFrame();
    } else {
      Serial.println("WiFi desconectado, reintentando...");
      connectWiFi();
    }
  }
}
