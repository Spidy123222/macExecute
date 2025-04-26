#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <arpa/inet.h>

#define PORT 8080
#define BUFFER_SIZE 1024

int main() {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if (!bundleID) bundleID = @"(null)";

        int server_fd, client_fd;
        struct sockaddr_in address;
        socklen_t addrlen = sizeof(address);
        char buffer[BUFFER_SIZE];

        const char *html_fmt =
            "HTTP/1.1 200 OK\r\n"
            "Content-Type: text/html\r\n\r\n"
            "<!DOCTYPE html>"
            "<html><head><title>Bundle ID</title></head>"
            "<body><h1>Hello from macOS!</h1><h2>Bundle ID: %s</h2></body></html>";

        char response[2048];
        snprintf(response, sizeof(response), html_fmt, [bundleID UTF8String]);

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
            send(client_fd, response, strlen(response), 0);
            close(client_fd);
        }

        close(server_fd);
    }
    return 0;
}

