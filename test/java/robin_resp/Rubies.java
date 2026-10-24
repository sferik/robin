/*
 * Rubies.java - the JRuby runtime the Java extension's tests share.
 *
 * Copyright (C) Robin contributors. Licensed under the LGPL-3.0.
 */
package robin_resp;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.File;
import java.util.List;
import org.jruby.Ruby;
import org.jruby.RubyInstanceConfig;
import org.jruby.exceptions.RaiseException;
import org.jruby.runtime.ThreadContext;
import org.jruby.runtime.builtin.IRubyObject;

/** A JRuby runtime with the extension and Robin's pure-Ruby RESP loaded. */
final class Rubies {
  static final Ruby RUBY = boot();

  static final boolean LOADED = new RobinRespService().basicLoad(RUBY);

  private Rubies() {}

  private static Ruby boot() {
    RubyInstanceConfig config = new RubyInstanceConfig();
    config.setLoadPaths(List.of(new File("lib").getAbsolutePath()));
    Ruby ruby = Ruby.newInstance(config);
    ruby.evalScriptlet("require 'socket'; require 'timeout'; require 'robin/redis/resp'");
    return ruby;
  }

  static ThreadContext context() {
    assertTrue(LOADED);
    return RUBY.getCurrentContext();
  }

  /** Runs Ruby code (with the extension loaded) and returns its value. */
  static IRubyObject eval(String code) {
    context();
    return RUBY.evalScriptlet(code);
  }

  /** The inspect of what the Ruby code returns. */
  static String inspect(String code) {
    return eval(code).inspect().toString();
  }

  /** Asserts the Ruby code returns something truthy. */
  static void check(String code) {
    assertTrue(eval(code).isTrue(), code);
  }

  /** Asserts the Ruby code raises the named exception with the given message. */
  static void raises(String error, String message, String code) {
    RaiseException raised = assertThrows(RaiseException.class, () -> eval(code), code);
    RUBY.getGlobalVariables().set("$robin_raised", raised.getException());
    assertEquals(
        "[\"" + error + "\", \"" + message + "\"]",
        inspect("[$robin_raised.class.name, $robin_raised.message]"),
        code);
  }
}
