#define _POSIX_C_SOURCE 199309L
#include <libxml/parser.h>
#include <libxml/xmlreader.h>
#include <stdio.h>
#include <stdlib.h>
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

    xmlInitParser();
    const int iterations = 6;

    double best_dom = 1e30;
    for (int i = 0; i < iterations; i++) {
        double start = now_sec();
        xmlDocPtr doc = xmlReadMemory(
            data, (int)size, "bench.xml", NULL,
            XML_PARSE_NONET | XML_PARSE_NOERROR | XML_PARSE_NOWARNING);
        if (!doc) {
            fprintf(stderr, "libxml2: parse failed\n");
            return 1;
        }
        xmlFreeDoc(doc);
        double elapsed = now_sec() - start;
        if (i != 0 && elapsed < best_dom) best_dom = elapsed;
    }

    double best_reader = 1e30;
    for (int i = 0; i < iterations; i++) {
        double start = now_sec();
        xmlTextReaderPtr reader = xmlReaderForMemory(
            data, (int)size, "bench.xml", NULL,
            XML_PARSE_NONET | XML_PARSE_NOERROR | XML_PARSE_NOWARNING);
        if (!reader) return 1;
        while (xmlTextReaderRead(reader) == 1) {
        }
        xmlFreeTextReader(reader);
        double elapsed = now_sec() - start;
        if (i != 0 && elapsed < best_reader) best_reader = elapsed;
    }

    double mb = (double)size / (1024.0 * 1024.0);
    printf("libxml2,dom,%.2f,%ld\n", mb / best_dom, rss_kb());
    printf("libxml2,reader,%.2f,%ld\n", mb / best_reader, rss_kb());
    xmlCleanupParser();
    free(data);
    return 0;
}
