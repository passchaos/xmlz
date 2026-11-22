#define _POSIX_C_SOURCE 199309L
#include <expat.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/resource.h>

static double now_sec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static long rss_kb(void) {
    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);
    return ru.ru_maxrss;
}

static void on_start(void *user, const XML_Char *name, const XML_Char **attrs) {
    (void)user; (void)name; (void)attrs;
}
static void on_end(void *user, const XML_Char *name) { (void)user; (void)name; }
static void on_text(void *user, const XML_Char *text, int len) {
    (void)user; (void)text; (void)len;
}

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    FILE *file = fopen(argv[1], "rb");
    if (!file) return 2;
    fseek(file, 0, SEEK_END);
    long size = ftell(file);
    fseek(file, 0, SEEK_SET);
    char *data = malloc((size_t)size);
    if (!data) return 2;
    if (fread(data, 1, (size_t)size, file) != (size_t)size) return 2;
    fclose(file);

    const int iterations = 6;
    double best = 1e30;
    for (int i = 0; i < iterations; i++) {
        double start = now_sec();
        XML_Parser parser = XML_ParserCreate(NULL);
        XML_SetElementHandler(parser, on_start, on_end);
        XML_SetCharacterDataHandler(parser, on_text);
        if (XML_Parse(parser, data, (int)size, 1) == XML_STATUS_ERROR) {
            fprintf(stderr, "expat: %s\n", XML_ErrorString(XML_GetErrorCode(parser)));
            return 1;
        }
        XML_ParserFree(parser);
        double elapsed = now_sec() - start;
        if (i != 0 && elapsed < best) best = elapsed;
    }
    double mb = (double)size / (1024.0 * 1024.0);
    printf("expat,sax,%.2f,%ld\n", mb / best, rss_kb());
    free(data);
    return 0;
}
