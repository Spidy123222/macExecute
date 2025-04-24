#include <stdio.h>
#include <string.h>

int main() {
    char input[256];

    printf("Hello World on macOS! (type 'exit' to quit):\n");

    while (1) {
        printf("> ");
        if (fgets(input, sizeof(input), stdin) == NULL) {
            break; // EOF or error
        }

        // Remove the newline character if present
        input[strcspn(input, "\n")] = '\0';

        if (strcmp(input, "exit") == 0) {
            break;
        }

        printf("You said: %s\n", input);
    }

    printf("Goodbye!\n");
    return 0;
}
