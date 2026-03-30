/**
 * CSI Passive Sniffer - ESP32-S3
 *
 * Captures Channel State Information from ambient WiFi frames without
 * associating to any AP. Locks to a single channel and filters CSI to
 * a configured anchor AP BSSID, providing a stable ~10 Hz baseline from
 * beacon frames plus bursts from data traffic.
 *
 * Output: JSON over UART (stdout) for bench testing. UDP streaming is
 * wired in but requires network connectivity (Phase 2b).
 *
 * Phase 2a scope — see EMB-14 research plan for full technical rationale.
 */

#include <stdio.h>
#include <string.h>
#include <math.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_system.h"
#include "nvs_flash.h"
#include "esp_netif.h"
#include "esp_timer.h"

static const char *TAG = "csi_passive";

/* Anchor MAC parsed from CONFIG_CSI_ANCHOR_MAC at startup */
static uint8_t s_anchor_mac[6] = {0};
static bool s_anchor_mac_set = false;

/**
 * Parse a "xx:xx:xx:xx:xx:xx" MAC string into a 6-byte array.
 * Returns true on success.
 */
static bool parse_mac(const char *str, uint8_t out[6])
{
    unsigned int b[6];
    if (sscanf(str, "%02x:%02x:%02x:%02x:%02x:%02x",
               &b[0], &b[1], &b[2], &b[3], &b[4], &b[5]) != 6) {
        return false;
    }
    for (int i = 0; i < 6; i++) out[i] = (uint8_t)b[i];
    return true;
}

static void wifi_csi_callback(void *ctx, wifi_csi_info_t *info)
{
    if (!info || !info->buf) return;

    /* Drop frames not from the anchor AP */
    if (s_anchor_mac_set &&
        memcmp(info->mac, s_anchor_mac, 6) != 0) {
        return;
    }

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

    /* UART output for bench testing (Phase 2a).
     * Pi-side can read via serial; UDP streaming added in Phase 2b. */
    printf("%s\n", json_buf);
}

static void wifi_init_passive(void)
{
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));

    /* No STA association — operate in null mode, then enable promiscuous */
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_NULL));
    ESP_ERROR_CHECK(esp_wifi_start());

    /* Lock to the configured channel */
    ESP_ERROR_CHECK(esp_wifi_set_channel(CONFIG_CSI_CHANNEL, WIFI_SECOND_CHAN_NONE));
    ESP_LOGI(TAG, "Locked to channel %d", CONFIG_CSI_CHANNEL);

    /* Enable promiscuous reception so CSI fires on all OFDM frames */
    ESP_ERROR_CHECK(esp_wifi_set_promiscuous(true));

    /* CSI config — LLTF only, 64 subcarriers, matches csi_rx format */
    wifi_csi_config_t csi_config = {
        .lltf_en = true,
        .htltf_en = false,         // disable HT-LTF to lock subcarrier count to 64
        .stbc_htltf2_en = false,   // disable STBC variant (would give 192 subcarriers)
        .ltf_merge_en = true,
        .channel_filter_en = false,
        .manu_scale = false,
        .shift = false,
    };
    ESP_ERROR_CHECK(esp_wifi_set_csi_config(&csi_config));
    ESP_ERROR_CHECK(esp_wifi_set_csi_rx_cb(wifi_csi_callback, NULL));
    ESP_ERROR_CHECK(esp_wifi_set_csi(true));

    ESP_LOGI(TAG, "Passive CSI sniffer active on channel %d", CONFIG_CSI_CHANNEL);
    if (s_anchor_mac_set) {
        ESP_LOGI(TAG, "Anchor MAC: %02x:%02x:%02x:%02x:%02x:%02x",
            s_anchor_mac[0], s_anchor_mac[1], s_anchor_mac[2],
            s_anchor_mac[3], s_anchor_mac[4], s_anchor_mac[5]);
    } else {
        ESP_LOGW(TAG, "No anchor MAC set — forwarding CSI from ALL sources");
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

    ESP_LOGI(TAG, "=== Axon Nervous System - CSI Passive Sniffer (Phase 2a) ===");

    /* Parse anchor MAC from config */
    const char *mac_str = CONFIG_CSI_ANCHOR_MAC;
    if (parse_mac(mac_str, s_anchor_mac)) {
        s_anchor_mac_set = true;
        ESP_LOGI(TAG, "Anchor MAC configured: %s", mac_str);
    } else {
        ESP_LOGW(TAG, "Invalid anchor MAC '%s' — will forward all CSI", mac_str);
    }

    wifi_init_passive();

    ESP_LOGI(TAG, "Streaming CSI JSON to UART. Waiting for beacon frames...");
    /* Nothing more to do — CSI arrives via callback */
}
