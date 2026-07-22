import { Craft } from "../sections/Craft";
import { Cta } from "../sections/Cta";
import { DeepDives } from "../sections/DeepDives";
import { Features } from "../sections/Features";
import { Hero } from "../sections/Hero";
import { NonGoals } from "../sections/NonGoals";
import { Numbers } from "../sections/Numbers";
import { Themes } from "../sections/Themes";

export function Landing() {
  return (
    <>
      <Hero />
      <Craft />
      <Features />
      <DeepDives />
      <NonGoals />
      <Themes />
      <Numbers />
      <Cta />
    </>
  );
}
