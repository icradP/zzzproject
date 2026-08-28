package main

import (
	"fmt"
	"log"

	webpush "github.com/SherClockHolmes/webpush-go"
)

func main() {
	privateKey, publicKey, err := webpush.GenerateVAPIDKeys()
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("ZZZ_VAPID_PUBLIC_KEY=%s\n", publicKey)
	fmt.Printf("ZZZ_VAPID_PRIVATE_KEY=%s\n", privateKey)
}
