  config, lib
}:
{
  options = {
    "kernel.sysrq".enable = "Enable all sysrq functions";  };
  config = {
    kernel.sysrq = "*";
  };
}
