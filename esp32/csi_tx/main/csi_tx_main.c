/**
 * CSI Transmitter - ESP32-S3
 *
 * Blasts probe/null data packets at ~100Hz for CSI sensing.
 * Partner ESP32-RX captures the channel state information
 * from these packets to detect presence and motion.
 */

#include <stdio.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_system.h"
#include "nvs_flash.h"
#include "esp_netif.h"
#include "lwip/sockets.h"

static const char *TAG = "csi_tx";

/* Configuration - adjust via menuconfig or here */
#define CSI_TX_SSID       CONFIG_CSI_TX_SSID
#define CSI_TX_PASSWORD   CONFIG_CSI_TX_PASSWORD
#define CSI_TX_CHANNEL    CONFIG_CSI_TX_CHANNEL
#define CSI_TX_RATE_MS    10  /* ~100Hz packet rate */

static void wifi_init_softap(void)
{
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_ap();

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));

    wifi_config_t wifi_config = {
        .ap = {
            .ssid = CSI_TX_SSID,
            .ssid_len = strlen(CSI_TX_SSID),
            .channel = CSI_TX_CHANNEL,
            .password = CSI_TX_PASSWORD,
            .max_connection = 4,
            .authmode = WIFI_AUTH_WPA2_PSK,
        },
    };

    if (strlen(CSI_TX_PASSWORD) == 0) {
        wifi_config.ap.authmode = WIFI_AUTH_OPEN;
    }

    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_AP));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_AP, &wifi_config));
    ESP_ERROR_CHECK(esp_wifi_start());

    ESP_LOGI(TAG, "SoftAP started. SSID:%s channel:%d",
             CSI_TX_SSID, CSI_TX_CHANNEL);
}

static void csi_tx_task(void *pvParameters)
{
    uint8_t probe_data[32] = {0};
    uint32_t seq = 0;

    /* UDP broadcast to the SoftAP subnet — RX receives these frames and
     * the CSI callback fires on each one. Avoids raw 802.11 frame injection. */
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
        .sin_addr.s_addr = inet_addr("192.168.4.255"),
    };

    ESP_LOGI(TAG, "Starting CSI TX at ~%dHz", 1000 / CSI_TX_RATE_MS);

    while (1) {
        memcpy(probe_data, &seq, sizeof(seq));  /* embed seq# for RX to detect drops */

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

    wifi_init_softap();

    xTaskCreate(csi_tx_task, "csi_tx", 4096, NULL, 5, NULL);
}
