/*
 * RobinRespService.java - defines Robin's JRuby extension. JRuby runs it
 * on `require "robin_resp/robin_resp"`, which finds robin_resp.jar.
 *
 * Copyright (C) Robin contributors. Licensed under the LGPL-3.0.
 */
package robin_resp;

import static org.jruby.api.Access.objectClass;
import static org.jruby.api.Define.defineModule;

import org.jruby.Ruby;
import org.jruby.RubyModule;
import org.jruby.runtime.ThreadContext;
import org.jruby.runtime.load.BasicLibraryService;

/** Defines Robin::Redis::NativeRESP, NativeIO and NativeSlots. */
public final class RobinRespService implements BasicLibraryService {
  @Override
  public boolean basicLoad(Ruby runtime) {
    ThreadContext context = runtime.getCurrentContext();
    // RubyModule#defineModuleUnder, not Define's (JRuby 10.1's), so it
    // builds on JRuby 10.0 too.
    RubyModule redis = defineModule(context, "Robin").defineModuleUnder(context, "Redis");
    redis.defineModuleUnder(context, "NativeRESP").defineMethods(context, NativeRESP.class);
    redis.defineModuleUnder(context, "NativeIO").defineMethods(context, NativeIO.class);
    redis
        .defineClassUnder(context, "NativeSlots", objectClass(context), NativeSlots::new)
        .defineMethods(context, NativeSlots.class);
    return true;
  }
}
