import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { verifyUser } from "../_shared/auth.ts";
import { createHandler } from "./handler.ts";

serve(createHandler({ verifyUser }));
