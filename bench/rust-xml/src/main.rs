//! Rust XML parser benchmark: quick-xml, roxmltree, and xml-rs on one input.
//!
//! Each engine parses the same file in its own process. Every row reports the
//! best of six timed iterations after one warm-up; parsing and releasing the
//! parsed tree are inside the timed region. File reading is outside it.
use std::hint::black_box;
use std::time::Instant;

fn rss_kb() -> u64 {
    let status = std::fs::read_to_string("/proc/self/status").unwrap_or_default();
    for line in status.lines() {
        if let Some(rest) = line.strip_prefix("VmHWM:") {
            if let Some(value) = rest.split_whitespace().next() {
                return value.parse().unwrap_or(0);
            }
        }
    }
    0
}

fn report(name: &str, mode: &str, mb: f64, best: f64) {
    println!("{name},{mode},{:.2},{}", mb / best, rss_kb());
}

fn best_of<F: FnMut() -> usize>(iterations: usize, mut run: F) -> f64 {
    let mut best = f64::INFINITY;
    for iteration in 0..iterations {
        let start = Instant::now();
        black_box(run());
        let elapsed = start.elapsed().as_secs_f64();
        if iteration != 0 && elapsed < best {
            best = elapsed;
        }
    }
    best
}

fn quick_xml_pull(data: &str) -> usize {
    let mut reader = quick_xml::Reader::from_str(data);
    let mut events = 0usize;
    loop {
        match reader.read_event() {
            Ok(quick_xml::events::Event::Eof) => break,
            Ok(_) => events += 1,
            Err(error) => panic!("quick-xml: {error}"),
        }
    }
    events
}

fn quick_xml_ns_pull(data: &str) -> usize {
    let mut reader = quick_xml::NsReader::from_str(data);
    let mut events = 0usize;
    loop {
        match reader.read_resolved_event() {
            Ok((_, quick_xml::events::Event::Eof)) => break,
            Ok(_) => events += 1,
            Err(error) => panic!("quick-xml ns: {error}"),
        }
    }
    events
}

fn roxmltree_dom(data: &str) -> usize {
    let document = roxmltree::Document::parse(data).expect("roxmltree");
    document.descendants().count()
}

fn xml_rs_pull(data: &str) -> usize {
    use xml::reader::{EventReader, XmlEvent};
    let parser = EventReader::new(data.as_bytes());
    let mut events = 0usize;
    for event in parser {
        match event {
            Ok(XmlEvent::EndDocument) => break,
            Ok(_) => events += 1,
            Err(error) => panic!("xml-rs: {error}"),
        }
    }
    events
}

fn main() {
    let mut args = std::env::args().skip(1);
    let path = args.next().expect("input path");
    let iterations: usize = args
        .next()
        .map(|value| value.parse().expect("iterations"))
        .unwrap_or(6);
    let data = std::fs::read_to_string(&path).expect("read input");
    let mb = data.len() as f64 / (1024.0 * 1024.0);

    let best = best_of(iterations, || quick_xml_pull(&data));
    report("quick-xml", "pull", mb, best);
    let best = best_of(iterations, || quick_xml_ns_pull(&data));
    report("quick-xml", "pull-ns", mb, best);
    let best = best_of(iterations, || roxmltree_dom(&data));
    report("roxmltree", "dom", mb, best);
    let best = best_of(iterations, || xml_rs_pull(&data));
    report("xml-rs", "pull", mb, best);
}
