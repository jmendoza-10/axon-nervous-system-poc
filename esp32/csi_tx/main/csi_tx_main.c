/**
 * CSI Transmitter - ESP32-S3
 *
 * Joins home WiFi as STA and blasts UDP broadcast packets at ~100Hz.
 * Partner ESP32-RX (also on home WiFi) captures CSI from these packets
 * and streams the data to the Raspberry Pi room node.
 */

#include <stdio.h>
#include <string.h>
#include <errno.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/event_groups.h"
#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_system.h"
#include "nvs_flash.h"
#include "esp_netif.h"
#include "lwip/sockets.h"

static const char *TAG = "csi_tx";

#define CSI_TX_SSID       CONFIG_CSI_TX_SSID
#define CSI_TX_PASSWORD   CONFIG_CSI_TX_PASSWORD
#define CSI_TX_RATE_MS    10  /* ~100Hz packet rate */

static EventGroupHandle_t s_wifi_event_group;
#define WIFI_CONNECTED_BIT BIT0

static void event_handler(void *arg, esp_event_base_t event_base,
                          int32_t event_id, void *event_data)
{
    if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_START) {
        esp_wifi_connect();
    } else if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_DISCONNECTED) {
        ESP_LOGW(TAG, "Disconnected, reconnecting...");
        esp_wifi_connect();
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *event = (ip_event_got_ip_t *)event_data;
        ESP_LOGI(TAG, "Connected. IP: " IPSTR, IP2STR(&event->ip_info.ip));
        xEventGroupSetBits(s_wifi_event_group, WIFI_CONNECTED_BIT);
    }
}

static void wifi_init_sta(void)
{
    s_wifi_event_group = xEventGroupCreate();

    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));

    esp_event_handler_instance_t instance_any_id;
    esp_event_handler_instance_t instance_got_ip;
    ESP_ERROR_CHECK(esp_event_handler_instance_register(
        WIFI_EVENT, ESP_EVENT_ANY_ID, &event_handler, NULL, &instance_any_id));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(
        IP_EVENT, IP_EVENT_STA_GOT_IP, &event_handler, NULL, &instance_got_ip));

    wifi_config_t wifi_config = {
        .sta = {
            .ssid     = CSI_TX_SSID,
            .password = CSI_TX_PASSWORD,
        },
    };
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wifi_config));
    ESP_ERROR_CHECK(esp_wifi_start());

    ESP_LOGI(TAG, "Connecting to %s...", CSI_TX_SSID);
    xEventGroupWaitBits(s_wifi_event_group, WIFI_CONNECTED_BIT,
                        pdFALSE, pdFALSE, portMAX_DELAY);
}

static void csi_tx_task(void *pvParameters)
{
    uint8_t probe_data[32] = {0};
    uint32_t seq = 0;

    /* UDP subnet broadcast — RX on the same network receives these frames
     * and the CSI callback fires on each one. */
    int sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (sock < 0) {
        ESP_LOGE(TAG, "Failed to create UDP socket");
        vTaskDelete(NULL);
        return;
    }
    int broadcast = 1;
    setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &broadcast, sizeof(broadcast));

    struct sockaddr_in dest = {
        .sin_family      = AF_INET,
        .sin_port        = htons(5501),
        .sin_addr.s_addr = inet_addr("255.255.255.255"),
    };

    ESP_LOGI(TAG, "Starting CSI TX at ~%dHz", 1000 / CSI_TX_RATE_MS);

    while (1) {
        memcpy(probe_data, &seq, sizeof(seq));

        ssize_t sent = sendto(sock, probe_data, sizeof(probe_data), 0,
                              (struct sockaddr *)&dest, sizeof(dest));
        if (sent < 0) {
            ESP_LOGW(TAG, "TX failed (errno %d)", errno);
        }

        seq++;
        if (seq % 1000 == 0) {
            ESP_LOGI(TAG, "TX packets sent: %lu", (unsigned long)seq);
        }

        vTaskDelay(pdMS_TO_TICKS(CSI_TX_RATE_MS));
    }
}

void app_main(void)
{
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);

    ESP_LOGI(TAG, "=== Axon Nervous System - CSI Transmitter ===");

    wifi_init_sta();

    xTaskCreate(csi_tx_task, "csi_tx", 4096, NULL, 5, NULL);
}
