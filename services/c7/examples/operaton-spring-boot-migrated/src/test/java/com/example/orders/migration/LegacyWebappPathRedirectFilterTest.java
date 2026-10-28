package com.example.orders.migration;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockFilterChain;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;

class LegacyWebappPathRedirectFilterTest {

  private final LegacyWebappPathRedirectFilter filter = new LegacyWebappPathRedirectFilter("/camunda", "/operaton");

  @Test
  void redirectsGetRequestsAndKeepsTheQuery() throws Exception {
    MockHttpServletResponse response = run("GET", "", "/camunda/app/cockpit/default/", "lang=de");

    assertThat(response.getStatus()).isEqualTo(302);
    // the #/process-instance/... fragment of a bookmark is not sent to the server; browsers re-apply it
    assertThat(response.getHeader("Location")).isEqualTo("/operaton/app/cockpit/default/?lang=de");
  }

  @Test
  void redirectsTheBarePathAndRespectsTheContextPath() throws Exception {
    assertThat(run("GET", "", "/camunda", null).getHeader("Location")).isEqualTo("/operaton");
    assertThat(run("HEAD", "/orders", "/orders/camunda/app/", null).getHeader("Location")).isEqualTo("/orders/operaton/app/");
  }

  @Test
  void passesThroughOtherMethodsAndOtherPaths() throws Exception {
    MockHttpServletResponse post = run("POST", "", "/camunda/api/admin/auth/user/default/login/cockpit", null);
    assertThat(post.getStatus()).isEqualTo(200);
    assertThat(post.getHeader("Location")).isNull();

    assertThat(run("GET", "", "/camundafoo/x", null).getHeader("Location")).isNull();
    assertThat(run("GET", "", "/engine-rest/version", null).getHeader("Location")).isNull();
    assertThat(run("GET", "", "/operaton/app/", null).getHeader("Location")).isNull();
  }

  @Test
  void supportsPermanentRedirects() throws Exception {
    LegacyWebappPathRedirectFilter permanent = new LegacyWebappPathRedirectFilter("/camunda/", "operaton", 301);
    MockHttpServletRequest request = request("GET", "", "/camunda/app/tasklist/", null);
    MockHttpServletResponse response = new MockHttpServletResponse();
    permanent.doFilter(request, response, new MockFilterChain());
    assertThat(response.getStatus()).isEqualTo(301);
    assertThat(response.getHeader("Location")).isEqualTo("/operaton/app/tasklist/");
  }

  @Test
  void refusesARedirectLoop() {
    // decision D6: as long as operaton.bpm.webapp.application-path is /camunda the filter must stay off
    assertThatThrownBy(() -> new LegacyWebappPathRedirectFilter("/camunda", "/camunda/"))
        .isInstanceOf(IllegalStateException.class)
        .hasMessageContaining("redirect would loop");
  }

  private MockHttpServletResponse run(String method, String contextPath, String uri, String query) throws Exception {
    MockHttpServletResponse response = new MockHttpServletResponse();
    filter.doFilter(request(method, contextPath, uri, query), response, new MockFilterChain());
    return response;
  }

  private static MockHttpServletRequest request(String method, String contextPath, String uri, String query) {
    MockHttpServletRequest request = new MockHttpServletRequest(method, uri);
    request.setContextPath(contextPath);
    request.setQueryString(query);
    return request;
  }
}
