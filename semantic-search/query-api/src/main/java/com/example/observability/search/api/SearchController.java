package com.example.observability.search.api;

import com.example.observability.search.application.TenantSearchService;
import com.example.observability.search.application.TenantSearchService.SearchExecution;
import java.net.URI;
import java.time.Duration;
import java.time.format.DateTimeParseException;
import java.util.List;
import org.springframework.http.HttpStatus;
import org.springframework.http.ProblemDetail;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.validation.annotation.Validated;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/v1/search")
@Validated
public class SearchController {
  private final TenantSearchService searchService;

  public SearchController(TenantSearchService searchService) {
    this.searchService = searchService;
  }

  @PostMapping
  public SearchResponse search(@Validated @RequestBody SearchRequest request,
      @AuthenticationPrincipal Jwt jwt) {
    SearchExecution execution = searchService.search(
        sanitize(request.query()),
        request.environment(),
        Duration.parse(request.timeRange()),
        request.topK(),
        request.mode(),
        jwt);
    return new SearchResponse(
        execution.queryId(),
        new SearchResponse.InterpretedFilters(
            execution.criteria().tenantId(),
            execution.criteria().environment(),
            execution.criteria().from().toString(),
            execution.criteria().to().toString()),
        execution.results().stream()
            .map(result -> new SearchResponse.ResultItem(
                result.documentId(),
                result.type(),
                result.score(),
                result.explanation(),
                result.summary(),
                result.evidence()))
            .toList());
  }

  private String sanitize(String query) {
    return query.replaceAll("[\\r\\n\\t]", " ").trim();
  }

  @ExceptionHandler({
      DateTimeParseException.class,
      HttpMessageNotReadableException.class,
      IllegalArgumentException.class,
      MethodArgumentNotValidException.class
  })
  @ResponseStatus(HttpStatus.BAD_REQUEST)
  ProblemDetail invalidRequest(Exception exception) {
    ProblemDetail detail = ProblemDetail.forStatusAndDetail(HttpStatus.BAD_REQUEST, exception.getMessage());
    detail.setTitle("Invalid search request");
    detail.setType(URI.create("https://example.com/problems/invalid-search-request"));
    return detail;
  }
}
