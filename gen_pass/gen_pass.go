package main

import (
	"bufio"
	"fmt"
	"os"
	"strings"

	"golang.org/x/crypto/bcrypt"
)

func main() {
	reader := bufio.NewReader(os.Stdin)

	fmt.Print("Введите пароль для хеширования: ")
	password, _ := reader.ReadString('\n')
	password = strings.TrimSpace(password)

	hashedPassword, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		panic(err)
	}

	fmt.Println("\nХеш пароля:")
	fmt.Println(string(hashedPassword))
}
