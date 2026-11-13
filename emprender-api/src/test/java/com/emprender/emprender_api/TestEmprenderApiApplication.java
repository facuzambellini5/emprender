package com.emprender.emprender_api;

import org.springframework.boot.SpringApplication;

public class TestEmprenderApiApplication {

	public static void main(String[] args) {
		SpringApplication.from(EmprenderApiApplication::main).with(TestcontainersConfiguration.class).run(args);
	}

}
