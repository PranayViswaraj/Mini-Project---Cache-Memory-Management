// shared self-check helpers for module-level testbenches
`define CHECK(cond, msg) begin checks = checks + 1; if (!(cond)) begin errors = errors + 1; $display("  FAIL: %s  (t=%0t)", msg, $time); end end
`define TB_REPORT(name) begin if (errors == 0) $display("TBRESULT %s PASS checks=%0d", name, checks); else $display("TBRESULT %s FAIL checks=%0d errors=%0d", name, checks, errors); end
