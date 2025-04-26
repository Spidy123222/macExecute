#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <arpa/inet.h>

#define PORT 8080
#define BUFFER_SIZE 1024

const char *response =
    "HTTP/1.1 200 OK\r\n"
    "Content-Type: text/html\r\n\r\n"
    "<!DOCTYPE html>"
    "<html><head><title>Simple macOS Web Server</title></head>"
    "<body><h1>Hello from macOS!</h1></body></html>";

int main() {
    int server_fd, client_fd;
    struct sockaddr_in address;
    socklen_t addrlen = sizeof(address);
    char buffer[BUFFER_SIZE];

    if ((server_fd = socket(AF_INET, SOCK_STREAM, 0)) == 0) {
        perror("Socket failed");
        exit(EXIT_FAILURE);
    }

    address.sin_family = AF_INET;
    address.sin_addr.s_addr = INADDR_ANY;
    address.sin_port = htons(PORT);
    if (bind(server_fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        perror("Bind failed");
        close(server_fd);
        exit(EXIT_FAILURE);
    }

    if (listen(server_fd, 1) < 0) {
        perror("Listen failed");
        close(server_fd);
        exit(EXIT_FAILURE);
    }

    printf("Web server running on http://localhost:%d\n", PORT);

    while (1) {
        if ((client_fd = accept(server_fd, (struct sockaddr *)&address, &addrlen)) < 0) {
            perror("Accept failed");
            continue;
        }

        read(client_fd, buffer, BUFFER_SIZE - 1);
        printf("Received request:\n%s\n", buffer);

        send(client_fd, response, strlen(response), 0);

        close(client_fd);
    }

    close(server_fd);
    return 0;
}

