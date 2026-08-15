{
  description = "Samsung Galaxy Book hardware fixes (speakers, mic, IPU6 webcam)";

  /*
    The one external this feature has. Owning it here is what makes the
    directory giftable: another Galaxy Book owner adds one input and one import,
    with nothing to transplant out of someone else's root flake.

    Pinned by tag in the URL -- flake = false inputs do not accept ref/rev.
  */
  inputs.samsung-galaxy-book-linux-fixes = {
    url = "github:Andycodeman/samsung-galaxy-book-linux-fixes/v0.3.50";
    flake = false;
  };

  outputs =
    { samsung-galaxy-book-linux-fixes, ... }:
    {
      fixes = samsung-galaxy-book-linux-fixes;
    };
}
