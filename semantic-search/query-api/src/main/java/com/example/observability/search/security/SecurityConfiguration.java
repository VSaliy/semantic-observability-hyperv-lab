package com.example.observability.search.security;

import org.springframework.beans.factory.ObjectProvider;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.config.Customizer;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.web.SecurityFilterChain;

@Configuration
public class SecurityConfiguration {
  @Bean
  SecurityFilterChain securityFilterChain(HttpSecurity http, ObjectProvider<JwtDecoder> jwtDecoder) throws Exception {
    // Spring Boot creates a decoder from spring.security.oauth2.resourceserver.jwt.issuer-uri or
    // jwk-set-uri; the dev profile supplies a shared-secret one. Without either there is no way to
    // validate tokens, and we refuse to start rather than fall back to a default secret.
    if (jwtDecoder.getIfAvailable() == null) {
      throw new IllegalStateException(
          "No JWT validation is configured. Set spring.security.oauth2.resourceserver.jwt.issuer-uri "
              + "(or jwk-set-uri), or activate the 'dev' Spring profile for local development only.");
    }
    return http
        .csrf(csrf -> csrf.disable())
        .authorizeHttpRequests(authorize -> authorize
            .requestMatchers("/actuator/health", "/actuator/info").permitAll()
            .anyRequest().authenticated())
        .oauth2ResourceServer(oauth2 -> oauth2.jwt(Customizer.withDefaults()))
        .build();
  }
}
