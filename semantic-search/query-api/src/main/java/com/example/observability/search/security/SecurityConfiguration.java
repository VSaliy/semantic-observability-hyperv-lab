package com.example.observability.search.security;

import java.util.List;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.boot.context.properties.bind.Bindable;
import org.springframework.boot.context.properties.bind.Binder;
import org.springframework.core.env.Environment;
import org.springframework.core.env.Profiles;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.config.Customizer;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.web.SecurityFilterChain;

@Configuration
public class SecurityConfiguration {
  private static final String AUDIENCES_PROPERTY = "spring.security.oauth2.resourceserver.jwt.audiences";

  @Bean
  SecurityFilterChain securityFilterChain(HttpSecurity http, ObjectProvider<JwtDecoder> jwtDecoder,
      Environment environment) throws Exception {
    // Spring Boot creates a decoder from spring.security.oauth2.resourceserver.jwt.issuer-uri or
    // jwk-set-uri; the dev profile supplies a shared-secret one. Without either there is no way to
    // validate tokens, and we refuse to start rather than fall back to a default secret.
    if (jwtDecoder.getIfAvailable() == null) {
      throw new IllegalStateException(
          "No JWT validation is configured. Set spring.security.oauth2.resourceserver.jwt.issuer-uri "
              + "(or jwk-set-uri), or activate the 'dev' Spring profile for local development only.");
    }
    // Spring Boot adds an audience validator to the decoder it builds when audiences are configured.
    // Without one, a token minted for another service by the same issuer would be accepted.
    if (!environment.acceptsProfiles(Profiles.of("dev"))
        && Binder.get(environment).bind(AUDIENCES_PROPERTY, Bindable.listOf(String.class))
            .orElse(List.of()).isEmpty()) {
      throw new IllegalStateException(
          "No accepted JWT audience is configured. Set " + AUDIENCES_PROPERTY + " to this API's audience.");
    }
    return http
        .csrf(csrf -> csrf.disable())
        .authorizeHttpRequests(authorize -> authorize
            .requestMatchers("/actuator/health", "/actuator/info").permitAll()
            .anyRequest().authenticated())
        .oauth2ResourceServer(oauth2 -> oauth2.jwt(Customizer.withDefaults()))
        .build();
  }

  @Bean
  JtiReplayValidator jtiReplayValidator(Environment environment) {
    return new JtiReplayValidator(!environment.acceptsProfiles(Profiles.of("dev")));
  }
}
