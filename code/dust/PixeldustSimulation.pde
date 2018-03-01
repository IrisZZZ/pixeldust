/* PixeldustSimulation Class
 *
 * requires Sound library
 *
 * Constructor parses config file and prepares audio and images.
 * Audio playback is triggered by begin().
 * Call run() every frame to cycle through images as audio is playing. Its retval indicates when audio is complete.
 * Then call fall() to finish off simulation. Its retval will indicate when control is ready to be passed back.
 */


class PixeldustSimulation {

  String audioFile;
  SoundFile audio;

  int w;  // operating width of simulation, i.e. max width of all scaled images
  int h;  // operating height of simulation, i.e. max height of all scaled images

  int[] times;
  int[] transitions;  // 1 if we transition normally, 0 for no transition

  int currentTime;      // reference to times[imgIndex], for convenience
  int currentInterval;  // total time we have to converge current image, calculated wrt simulation startTime

  ArrayList<Particle> particles = new ArrayList<Particle>();

  int startTime;  // set by begin() to track when audio starts

  PImage[] imgs = new PImage[0];
  String[] imgNames;  // was imageFiles
  int imgIndex = -1;  // currentIndex was folded into here

  float brightnessThreshold = 254;  // do no create particles from pixels lighter than this

  PImage frame;  // PImage used as off-screen graphics buffer, used to make resizing easier, initialized in initImages with w and h

  int prevTime;  // Stores the last time we drew a frame, used for animation timing

  boolean isFallen;  // Keeps track of if particles have fallen past a threshold, marks effective end of simulation

  /* Constructor
   *
   * It's rather silly that because of how SoundFile works we need to
   * pass the global PApplet reference. Maybe there is a more clever way?
   *
   * param ref     PApplet reference to global PApplet
   * param csvFile String name of csv file
   * should change to accept name of csv file!
   */
  PixeldustSimulation(PApplet ref, String csvFile, float scaleImg) {
    println("[" + millis() + "] Creating PixeldustSimulation");

    // parse control file and initialize audioFile, imageFiles, and times
    parse(csvFile);

    // initialize audio
    initAudio(ref);

    // initializes w, h, and imgs[]
    initImages(scaleImg);
  }

  PixeldustSimulation(PApplet ref, String csvFile, float scaleImg, ArrayList<Particle> particles) {
    this(ref, csvFile, scaleImg);

    this.particles = particles;  // initializes with particles that were passed in
  }


  /* Parses controlling csv file and sets audioFile, imageFiles, and times fields
   *
   * Assume first row is audio file and remaining rows are image/time pairs.
   *
   * Ref: Handbook Ch 32 (Data)
   */
  void parse(String csvFile) {

    Table table = loadTable(csvFile);
    println("[" + millis() + "] Parsing", csvFile, "with", table.getRowCount(), "rows and", table.getColumnCount(), "columns");

    int numRows = table.getRowCount();

    // gets name of audio file
    audioFile = table.getString(0, 0);
    println("\t" + audioFile);

    // gets names of image files and their times
    imgNames = new String[numRows-1];
    transitions = new int[numRows-1];
    String[] timestamps = new String[numRows-1];
    for (int i = 1; i < numRows; i++) {
      imgNames[i-1] = table.getString(i, 0);
      timestamps[i-1] = table.getString(i, 1);
      transitions[i-1] = table.getInt(i, 2);
    }

    // converts M:S to milliseconds
    times = new int[timestamps.length];
    for (int i = 0; i < timestamps.length; i++) {
      times[i] = convertTime(timestamps[i]);
    }

    times = new int[timestamps.length];
    for (int i = 0; i < timestamps.length; i++) {
      times[i] = convertTime(timestamps[i]);
    }  

    // TODO validate data and that times are well ordered
    for (int i = 0; i < imgNames.length; i++) {
      println("\t" + imgNames[i] + ", " + timestamps[i] + ", " + times[i]);
    }
  }

  // helper function to convert minutes:seconds to milliseconds
  int convertTime(String timestamps) {
    String[] time = split(timestamps, ':');
    if (time.length != 2) {
      println("Error: time format");
      exit();
    }
    int minutes = int(time[0]);
    int seconds = int(time[1]);
    return (minutes * 60 + seconds)*1000;
  }


  /* Initializes audio field
   *
   * Must be called after audioFile initialized in parse()
   */
  void initAudio(PApplet ref) {
    println("[" + millis() + "] Initializing " + audioFile);
    audio = new SoundFile(ref, audioFile);

    println("\tSFSampleRate= " + audio.sampleRate() + " Hz");
    println("\tSFSamples= " + audio.frames() + " samples");
    println("\tSFDuration= " + audio.duration() + " seconds");
  }


  /* Initializes w, h, and images[] fields
   *
   * Must be called after imagesFiles array is initialized in parse()
   */
  void initImages(float scaleImg) {
    w = 0;
    h = 0;

    for (int i = 0; i < imgNames.length; i++) {
      print("[" + millis() + "] Loading", imgNames[i]);
      PImage newImg = loadImage(imgNames[i]);
      newImg.resize(floor(newImg.width/scaleImg), 0);
      imgs = (PImage[])append(imgs, newImg);

      switch(newImg.format) {
      case RGB:
        println(" (RGB format)");
        break;
      case ARGB:
        println(" (ARGB format)");
        break;
      case ALPHA:
        println(" (ALPHA format)");
        break;
      default:
        println(" (unknown format)");
      }

      // set simulation dimensions to the max of all images
      if (imgs[i].width > w) {
        w = imgs[i].width;
      }
      if (imgs[i].height > h) {
        h = imgs[i].height;
      }
    }

    for (PImage img : imgs) {
      if (img.width != w || img.height != h) {
        println("Warning: Images have different dimensions");
      }
    }

    println("[" + millis() + "] Initialized", imgs.length, "images at", w + "x" + h);

    frame = createImage(w, h, RGB);
  }


  /* Begin audio and set up for run
   *
   * Begin playing audio and set first image, now we can run().
   */
  void begin() {
    println("[" + millis() + "] Playing " + audioFile);
    audio.play();

    startTime = millis();  // marks the time the simulation starts

    nextImage();  // imgIndex is initialized to -1 so we start off correctly

    prevTime = millis();  // first frameTime calculation causes weirdness if this is not reset, there are still bugs

    isFallen = false;  // resets fall state, ignored until fall phase
  }


  /* Main event loop to be called from draw()
   *
   * Should not be called until after this.begin() has been called once
   *
   * returns 1 if simulation is complete, otherwise return 0
   */
  int run() {
    // calculates progress of current image from 0 (start) to 1 (complete)
    float pct = 1 - float(currentTime - elapsedTime()) / currentInterval;
    pct = constrain(pct, 0, 1);  // ensures pct stays in range 0-1 or else strange things happen

    display(true);  // performs update then displays

    if (debug) {
      // displays progress indicator for this segment
      noStroke();
      fill(255, 0, 0);
      rect(0, height-4, map(pct, 0, 1, 0, width), 4);
    }

    // starts next image once we have reached desired convergence time, will typcally overshoot by 10s of ms
    if (elapsedTime() > currentTime) {
      // advance image if there are still more
      if (imgIndex < imgs.length-1) {
        nextImage();
      } else if (imgIndex == imgs.length-1) {
        // tests if we're actually done since audio may continue past timestamp of final image
        if (elapsedTime() > audio.duration()*1000) {
          audio.stop();
          println("complete @", elapsedTime(), "/", audio.duration()*1000);
          return 1;  // all other conditions fall through to return 0
        } else {
          println( "wrapping up @", elapsedTime());
        }
      }
    }
    return 0;  // indicates that we're still running
  }

  /*
   * Makes particles fall
   *
   * Should be called instead of run() after simulation is complate.
   * Performs a custom update and displays.
   *
   * @return    a boolean indicating if particles have fallen below threshold
   */
  boolean fall() {
    float triggerThreshold = 0.5;  // amount of falling before we can retrigger, 0 = we can retrigger right away, closer to 1 means longer wait, 1 will never retrigger

    // iterates through particles and make them fall
    for (int i = 0; i < particles.size(); i++) {
      Particle particle = particles.get(i);
      particle.acc = new PVector(0, 0);
      particle.vel = new PVector(random(-3, 3), .03 * (h - particle.pos.y) * particle.mass);
      particle.update();
      particle.updateRandom(random(20), random(40));  // adds a little bit of randomness to particles linger at bottom
      // TODO currently there is no boundary condition so particles will eventually diffuse off screen if above dynamics allow, currently I think they will accumulate just barely out of sight
      // Removes particles that are out of bounds. Note this diverges from the original "Particles to image" by Labbe approach.
      // TODO Use Iterator.remove() to do this properly, or iterate in reverse, or else we may miss some if there are consecutive to remove
      //if (particle.isOutOfBounds(0, 0, w, h)) {
      //  sim.particles.remove(i);  // consider if remove is the right thing to do here...!
      //}
    }

    display();

    if (isFallen == false) {
      // Only tests fall if need. This condition is only for optimization since it prevents unnecessary retesting.
      isFallen = true;  // assumes we have fallen until we observe evidence to the contrary
      for (int i = 0; i < particles.size(); i++) {
        // checks that all particles have fallen below a threshold
        if (particles.get(i).pos.y < h * triggerThreshold) {
          //fall is not complete if we spot any particle above the threshold
          isFallen = false;
          break;  // escapes loop once we can say fall is not complete
        }
      }
    }
    return isFallen;
  }

  /* Returns elapsed time in milliseconds (elapsed time is time since begin() was called) 
   */
  int elapsedTime() {
    return millis() - startTime;
  }

  /*
   * Returns the time remaining for this image
   *
   * @return   time in milliseconds until current image should converge, may be negative in brief moments of overshooting
   */
  int timeLeft() {
    return currentTime - elapsedTime();
  }


  /**
   Dynamically adds/removes particles to make up the next image.
   *
   * Sets currentTime and currentInterval.
   */
  void nextImage() {

    // Moved here from setCurrent(), would be nice to eventually find a way to print this for last image, and maybe suppress for first
    println("\telapsed time:", elapsedTime(), "| actual interval ->", currentInterval + elapsedTime() - currentTime);

    // Switch index to next image. Note: logic in run() bounds tests this aleady but doesn't hurt to leave in.
    imgIndex++;
    if (imgIndex > imgs.length-1) {
      imgIndex = 0;
    }
    imgs[imgIndex].loadPixels();

    // Moved here from setCurrent()
    println("[" + millis() + "] Starting", imgNames[imgIndex]);
    currentTime = times[imgIndex];
    // computes target time relative to time elapsed since start of sim
    // will typically be some 10s of ms less than expected time because of error in catching the time condition
    currentInterval = (currentTime - elapsedTime());
    println("\tset: imgIndex =", imgIndex, "| currentTime =", currentTime, "| currentInterval =", currentInterval);

    // Create an array of indexes from particle array.
    ArrayList<Integer> particleIndexes = new ArrayList<Integer>();
    for (int i = 0; i < particles.size(); i++) {
      particleIndexes.add(i);
    }

    // Clears particleIndexes for an additive transition. Existing particles and targets remain.
    if (transitions[imgIndex] == 0) {
      // Clears particleIndexes so no particles will be reassigned. New particles will be created for all threshold pixels.
      particleIndexes.clear();
    }

    // Go through each pixel of the image.
    int pixelIndex = 0;
    for (int y = 0; y < imgs[imgIndex].height; y++) {
      for (int x = 0; x < imgs[imgIndex].width; x++) {
        // Get the pixel's color.
        color pixel = imgs[imgIndex].pixels[pixelIndex];

        pixelIndex += 1;

        // Do not assign a particle to this pixel under some conditions
        if (brightness(pixel) > brightnessThreshold) {
          continue;
        }

        // Assigns particles to new pixels, creating new ones if needed 
        Particle newParticle;
        if (imgIndex == 0 && particleIndexes.isEmpty()) {
          // Initializes particles for the first image on the bottom edge if starting from scratch
          // If particles were passed in this block is skipped and we recycle them as usual, since aparticleIndexes will not be empty 
          newParticle = new Particle(random(0, this.w), this.h - 1);
          particles.add(newParticle);
        } else if (particleIndexes.size() > 0) {
          // Re-use existing particle.
          // JS Array splice can handle non-int params it seems, but ArrayList.remove fails, also was originally length-1
          int index = particleIndexes.remove(int(random(particleIndexes.size())));
          newParticle = particles.get(index);
        } else {
          // Create a new particle since all existing particles have already been used
          // Place new particle at the same location as a randomly selected existing particle
          Particle randomParticle = particles.get(int(random(particles.size())));
          newParticle = new Particle(randomParticle.pos.x, randomParticle.pos.y);
          particles.add(newParticle);
        }

        newParticle.target.x = x+this.w/2-imgs[imgIndex].width/2;
        newParticle.target.y = y+this.h/2-imgs[imgIndex].height/2;
        newParticle.currentColor = pixel;
      }
    }

    // Kill off any left over particles that aren't assigned to anything.
    if (particleIndexes.size() > 0) {
      for (int i = 0; i < particleIndexes.size(); i++) {
        particles.get(particleIndexes.get(i)).kill();
      }
    }

    // Immediately removes these killed particles if we are just starting this person and have passed in particles
    if (particleIndexes.size() > 0 && imgIndex == 0) {
      for (int i = particles.size()-1; i > -1; i--) {
        if (particles.get(i).isKilled) {
          particles.remove(i);
        }
      }
    }

    println("\tUsing", nfc(particles.size()), "particles w/", particleIndexes.size(), "killed");
  }


  /*
   * Simply displays particles, optionally updates first, does not do bounds checking
   *
   * @param doUpdate  boolean which indicates if an update should also be performed 
   */
  void display(boolean doUpdate) {
    background(0);
    frame.loadPixels();
    for (int i = 0; i < frame.pixels.length; i++) {
      // Sets background to white
      frame.pixels[i] = color(255);
    }

    int frameTime = millis() - prevTime;  // calculates how long the previous frame took to render
    prevTime = millis();

    for (int i = particles.size()-1; i > -1; i--) {
      if (doUpdate) {
        particles.get(i).move(timeLeft(), frameTime);
      }
      if (particles.get(i).isKilled && particles.get(i).isOutOfBounds(0, 0, this.w, this.h)) {
        // Removes particles that are out of bounds and killed
        particles.remove(i);
      // Commenting out this section prevents snapping of pixels
      } else if (particles.get(i).pos.dist(particles.get(i).target) < 1 && !particles.get(i).isKilled) {
        // Clamps particles to their target if they are very close, checking not killed may be redundant or unnecessary but makes doubly sure we don't clamp to some out of bounds target
        // Note we intentionally allow these particles to be (slightly) out of bounds
        // Corrects numerical artifacts of pixel binning by clamping particles to their targets
        int loc = int(particles.get(i).target.x) + int(particles.get(i).target.y) * w;
        frame.pixels[loc] = particles.get(i).currentColor;
      } else if (!particles.get(i).isOutOfBounds(0, 0, this.w, this.h)) {
        // Only considers particles that are within bounds since otherwise loc will be invalid
        int loc = int(particles.get(i).pos.x) + int(particles.get(i).pos.y) * w;  // gets this pixels index in pixels[]
        if (brightness(frame.pixels[loc]) > brightness(particles.get(i).currentColor)) {
          // Updates pixel if it should be darker
          frame.pixels[loc] = particles.get(i).currentColor;
        }
      } // No action is taken on live particles that are out of bounds but not close to their targets!
    }

    // For debugging, also render particles at their targets, this means pixels may be rendered twice and if a pixel is occupied by a particle that is darker than that pixel's target color then it may be obscured
    if (keyPressed && key == 't') {
      for (int i = 0; i < particles.size(); i++) {
        int loc = int(particles.get(i).target.x) + int(particles.get(i).target.y) * w;
        if (loc >= 0 && loc < frame.pixels.length) {
          // Render particle at its target, assuming it's in bounds, note condition effectively like testing isOutOfBounds but for target position
          frame.pixels[loc] = particles.get(i).currentColor;
        }
      }
    }

    frame.updatePixels();
    float aspect = float(w)/float(h);
    image(frame, 0, height / 2 - ( width / aspect) / 2, width, width / aspect);  // Fits to screen, adapts if screen is taller than sim, but not if wider
  }


  /*
   * Simply displays particles, does not update or do bounds checking
   */
  void display() {
    display(false);
  }
}