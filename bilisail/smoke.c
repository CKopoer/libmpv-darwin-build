#include <mpv/client.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    mpv_handle *player = mpv_create();
    if (!player || mpv_set_option_string(player, "vo", "null") < 0 ||
        mpv_set_option_string(player, "ao", "null") < 0 || mpv_initialize(player) < 0)
        return 1;
    char *vos = mpv_get_property_string(player, "option-info/vo/choices");
    int ok = vos && strstr(vos, "gpu-next");
    printf("libmpv client %lu, gpu-next %d\n", mpv_client_api_version(), ok);
    mpv_free(vos);
    mpv_terminate_destroy(player);
    return !ok;
}
