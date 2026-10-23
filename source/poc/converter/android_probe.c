#include <stdio.h>

/* Rust returns a status after converting its original EPUB fixture in memory. */
extern int brizfi_converter_poc_probe(void);

int main(void) {
    int status = brizfi_converter_poc_probe();
    printf("BRIZFI converter native probe: status=%d\n", status);
    return status;
}
