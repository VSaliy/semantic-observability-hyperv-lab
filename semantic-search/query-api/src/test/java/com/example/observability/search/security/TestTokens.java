package com.example.observability.search.security;

import com.nimbusds.jose.JOSEException;
import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.JWSHeader;
import com.nimbusds.jose.crypto.MACSigner;
import com.nimbusds.jose.crypto.RSASSASigner;
import com.nimbusds.jose.jwk.RSAKey;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.SignedJWT;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.Date;
import java.util.UUID;

final class TestTokens {
  private TestTokens() {}

  static String hs256(String secret, String issuer, String tenant) throws JOSEException {
    SignedJWT jwt = new SignedJWT(new JWSHeader(JWSAlgorithm.HS256), claims(issuer, tenant));
    jwt.sign(new MACSigner(secret.getBytes(StandardCharsets.UTF_8)));
    return jwt.serialize();
  }

  static String rs256(RSAKey key, String tenant, String audience) throws JOSEException {
    return rs256WithJti(key, tenant, audience, UUID.randomUUID().toString());
  }

  static String rs256WithJti(RSAKey key, String tenant, String audience, String jti) throws JOSEException {
    SignedJWT jwt = new SignedJWT(
        new JWSHeader.Builder(JWSAlgorithm.RS256).keyID(key.getKeyID()).build(),
        claims(null, tenant, audience, jti));
    jwt.sign(new RSASSASigner(key));
    return jwt.serialize();
  }

  private static JWTClaimsSet claims(String issuer, String tenant) {
    return claims(issuer, tenant, null, UUID.randomUUID().toString());
  }

  private static JWTClaimsSet claims(String issuer, String tenant, String audience, String jti) {
    JWTClaimsSet.Builder builder = new JWTClaimsSet.Builder()
        .subject("test-user")
        .claim("tenant", tenant)
        .issueTime(Date.from(Instant.now().minusSeconds(60)))
        .expirationTime(Date.from(Instant.now().plusSeconds(600)));
    if (jti != null) {
      builder.jwtID(jti);
    }
    if (audience != null) {
      builder.audience(audience);
    }
    if (issuer != null) {
      builder.issuer(issuer);
    }
    return builder.build();
  }
}
