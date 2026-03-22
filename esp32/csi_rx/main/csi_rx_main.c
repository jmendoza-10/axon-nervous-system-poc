/**
 * CSI Receiver - ESP32-S3
 *
 * Connects to the CSI TX soft-AP and captures Channel State Information
 * from incoming packets. Streams CSI data as JSON over UDP to the
 * parent Raspberry Pi for processing.
 */

#include <stdio.h>
#include <string.h>
#include <math.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/event_groups.h"
#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_system.h"
#include "nvs_flash.h"
#include "esp_netif.h"
#include "esp_timer.h"
#include "lwip/sockets.h"

static const char *TAG = "csi_rx";

/* Configuration */
#define CSI_RX_SSID       CONFIG_CSI_RX_SSID
#define CSI_RX_PASSWORD   CONFIG_CSI_RX_PASSWORD
#define UDP_TARGET_IP     CONFIG_CSI_UDP_TARGET_IP
#define UDP_TARGET_PORT   CONFIG_CSI_UDP_TARGET_PORT

static EventGroupHandle_t s_wifi_event_group;
#define WIFI_CONNECTED_BIT BIT0

static int udp_sock = -1;
static struct sockaddr_in dest_addr;

static void udp_init(void)
{
    dest_addr.sin_addr.s_addr = inet_addr(UDP_TARGET_IP);
    dest_addr.sin_family = AF_INET;
    dest_addr.sin_port = htons(UDP_TARGET_PORT);

    udp_sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_IP);
    if (udp_sock < 0) {
        ESP_LOGE(TAG, "Failed to create UDP socket");
    } else {
        ESP_LOGI(TAG, "UDP socket ready → %s:%d", UDP_TARGET_IP, UDP_TARGET_PORT);
    }
}

static void wifi_csi_callback(void *ctx, wifi_csi_info_t *info)
{
    if (!info || !info->buf || udp_sock < 0) return;

    /* Build a compact JSON payload with CSI amplitude data */
    static char json_buf[2048];
    int len = 0;

    len += snprintf(json_buf + len, sizeof(json_buf) - len,
        "{\"mac\":\"%02x:%02x:%02x:%02x:%02x:%02x\","
        "\"rssi\":%d,\"channel\":%d,\"len\":%d,"
        "\"timestamp\":%lld,\"data\":[",
        info->mac[0], info->mac[1], info->mac[2],
        info->mac[3], info->mac[4], info->mac[5],
        info->rx_ctrl.rssi,
        info->rx_ctrl.channel,
        info->len,
        (long long)esp_timer_get_time());

    /* Extract amplitude from I/Q pairs: amplitude = sqrt(I^2 + Q^2) */
    int num_subcarriers = info->len / 2;
    for (int i = 0; i < num_subcarriers && len < (int)sizeof(json_buf) - 32; i++) {
        int8_t imag = info->buf[i * 2];
        int8_t real = info->buf[i * 2 + 1];
        float amplitude = sqrtf((float)(real * real + imag * imag));

        if (i > 0) json_buf[len++] = ',';
        len += snprintf(json_buf + len, sizeof(json_buf) - len, "%.1f", amplitude);
    }

    len += snprintf(json_buf + len, sizeof(json_buf) - len, "]}");

    sendto(udp_sock, json_buf, len, 0,
           (struct sockaddr *)&dest_addr, sizeof(dest_addr));
}

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
            .ssid = CSI_RX_SSID,
            .password = CSI_RX_PASSWORD,
        },
    };
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wifi_config));
    ESP_ERROR_CHECK(esp_wifi_start());

    /* Enable CSI collection */
    wifi_csi_config_t csi_config = {
        .lltf_en = true,
        .htltf_en = true,
        .stbc_htltf2_en = true,
        .ltf_merge_en = true,
        .channel_filter_en = false,
        .manu_scale = false,
        .shift = false,
    };
    ESP_ERROR_CHECK(esp_wifi_set_csi_config(&csi_config));
    ESP_ERROR_CHECK(esp_wifi_set_csi_rx_cb(wifi_csi_callback, NULL));
    ESP_ERROR_CHECK(esp_wifi_set_csi(true));

    ESP_LOGI(TAG, "WiFi STA + CSI initialized. Connecting to %s...", CSI_RX_SSID);

    xEventGroupWaitBits(s_wifi_event_group, WIFI_CONNECTED_BIT,
                        pdFALSE, pdFALSE, portMAX_DELAY);
}

void app_main(void)
{
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);

    ESP_LOGI(TAG, "=== Axon Nervous System - CSI Receiver ===");

    wifi_init_sta();
    udp_init();

    ESP_LOGI(TAG, "CSI RX running. Streaming to %s:%d", UDP_TARGET_IP, UDP_TARGET_PORT);
}
