/*
 * RobinRespService.java - defines Robin's JRuby extension. JRuby runs it
 * on `require "robin_resp/robin_resp"`, which finds robin_resp.jar.
 *
 * Copyright (C) Robin contributors. Licensed under the LGPL-3.0.
 */
package robin_resp;

import static org.jruby.api.Access.objectClass;
import static org.jruby.api.Define.defineModule;
import static org.jruby.api.Define.defineModuleUnder;

import org.jruby.Ruby;
import org.jruby.RubyModule;
import org.jruby.runtime.ThreadContext;
import org.jruby.runtime.load.BasicLibraryService;

/** Defines Robin::Redis::NativeRESP, NativeIO and NativeSlots. */
public final class RobinRespService implements BasicLibraryService {
  @Override
  public boolean basicLoad(Ruby runtime) {
    ThreadContext context = runtime.getCurrentContext();
    RubyModule redis = defineModuleUnder(context, defineModule(context, "Robin"), "Redis");
    defineModuleUnder(context, redis, "NativeRESP").defineMethods(context, NativeRESP.class);
    defineModuleUnder(context, redis, "NativeIO").defineMethods(context, NativeIO.class);
    redis
        .defineClassUnder(context, "NativeSlots", objectClass(context), NativeSlots::new)
        .defineMethods(context, NativeSlots.class);
    return true;
  }
}
