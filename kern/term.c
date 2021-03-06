#include	"u.h"
#include	"lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"error.h"

#define Image IMAGE
#include	<draw.h>
#include	<memdraw.h>
#include	<cursor.h>
#include	"screen.h"

enum
{
	Border = 4
};

static struct {
	Lock	lk;
	Memsubfont *font;
	int tabx;	/* width of tab */
	int spacex;	/* width of space */
	int xpos;
	Memimage *fg;	/* text color */
	Memimage *bg;	/* background color */
	Memimage *screen;	/* screen image - can change! */
	Memimage *grey;
	Rectangle flushr;	/* rectangle needs flushing */
	Rectangle text;	/* rectangle holding text */
	Rectangle maxtext;	/* total space for text */
	Rectangle line;	/* remainder of current output line */
	char *lputs;	/* last termputs string */
	int ln;			/* last termputs length */
} term;

static void termputs(char*, int);
//static void showkmesg(void);
static void kickscreen(void);

void
terminit(void)
{
	Memimage *grey;

	lock(&term.lk);
	memimageinit();
	term.font = getmemdefont();
	term.fg = memblack;
	term.bg = memwhite;

	term.spacex = memsubfontwidth(term.font, " ").x;
	term.tabx = term.spacex * 8;

	/* a lot of work to get a grey color */
	grey = allocmemimage(Rect(0,0,1,1), CMAP8);
	grey->flags |= Frepl;
	grey->clipr = Rect(-100000, -100000, 100000, 100000);
	memfillcolor(grey, 0x777777FF);
	term.grey = grey;

	term.flushr = Rect(0, 0, 0, 0);
	/* termreplacescreenimage called when it is ready */
	unlock(&term.lk);

	/* maybe it already has */
	if(term.screen)
		termreplacescreenimage(term.screen);

	screenputs = termputs;
	kickscreen();
}

static void
addflush(Rectangle r)
{
	if(term.flushr.min.x >= term.flushr.max.x)
		term.flushr = r;
	else
		combinerect(&term.flushr, r);
}

static void
termcursor(int on)
{
	Rectangle r;

	r = term.line;
	r.max.x = r.min.x+2;
	if(on)
		memimagedraw(term.screen, r, term.grey, ZP, memopaque, ZP, S);
	else
		memimagedraw(term.screen, r, term.bg, ZP, memopaque, ZP, S);
	addflush(r);
}

static void
_termreplacescreenimage(Memimage *m)
{
	int h;
	Rectangle r, r0;
	int mopen;

	if(term.bg == nil){
		/* not yet init */
		term.screen = m;
		return;
	}

	mopen = mouseopened();

	/* white background */
	if(!mopen)
		memimagedraw(m, m->r, term.bg, ZP, memopaque, ZP, S);
	
	/* grey heading: Plan 9 VX */
	r = m->r;
	h = term.font->height;
	r.max.y = r.min.y + Border + h + Border;
	if(!mopen){
		memimagedraw(m, r, term.grey, ZP, memopaque, ZP, S);
		memimagestring(m, addpt(r.min, Pt(Border, Border)),
			memwhite, ZP, term.font, "Plan 9 drawterm console");
	}
	r.min.y = r.max.y;
	r.max.y += 2;
	if(!mopen){
		memimagedraw(m, r, memblack, ZP, memopaque, ZP, S);
	}

	/* text area */
	r.min.x += Border;
	r.max.x -= Border;
	r.min.y = r.max.y;
	r.max.y = m->r.max.y;
	r.max.y = r.min.y + Dy(r)/h*h;
	term.maxtext = r;

	/* occupied text area - just one blank line */
	r0 = r;
	r0.max.y = r0.min.y + h;
	term.text = r0;
	term.line = r0;

	/* ready to commit */
	term.screen = m;
	if(!mopen){
		// showkmesg();
		termcursor(1);
		flushmemscreen(m->r);
	}
}

void
termreplacescreenimage(Memimage *m)
{
	Proc *p;
	int cpupid;

	cpupid = 1;
	p = up;
	
#if defined(COCOA)
	if(p && p->pid == 1){
		cpupid = 0;
	}
#endif

	if(p && cpupid == 1){
		drawqlock();
		lock(&term.lk);
		_termreplacescreenimage(m);
		unlock(&term.lk);
		drawqunlock();
	} else {
		lock(&term.lk);
		_termreplacescreenimage(m);
		unlock(&term.lk);
	}
	if(!mouseopened())
		termputs(term.lputs, term.ln);
}

void
termredraw(void)
{
	Memimage *m;

	if(!term.screen)
		return;

	drawqlock();
	lock(&term.lk);
	m = term.screen;
	term.screen = nil;
	if(m)
		_termreplacescreenimage(m);
	unlock(&term.lk);
	drawqunlock();
}

static void
termscroll(void)
{
	Rectangle r0, r1;
	int dy, h;
	
	dy = Dy(term.maxtext) / 2;
	h = term.font->height;
	dy = dy/h*h;
	if(dy < term.font->height)
		dy = term.font->height;
	r0 = term.text;
	r1 = term.text;
	r0.max.y -= dy;
	r1.min.y += dy;
	memimagedraw(term.screen, r0, term.screen, r1.min,
		memopaque, ZP, S);
	r1.min.y = r0.max.y;
	memimagedraw(term.screen, r1, term.bg, ZP, memopaque, ZP, S);
	addflush(r0);
	addflush(r1);
	term.text = r0;
}

static void
termputc(Rune r)
{
	int dx, n;
	Rectangle rect;
	char buf[UTFmax+1];
	Memsubfont *font;
	
	font = term.font;

	switch(r){
	case '\n':
		if(term.text.max.y >= term.maxtext.max.y)
			termscroll();
		term.text.max.y += font->height;
		/* fall through */
	case '\r':
		term.line = term.text;
		term.line.min.y = term.line.max.y - font->height;
		break;
	case '\t':
		dx = term.tabx - (term.line.min.x - term.text.min.x) % term.tabx;
		if(term.line.min.x+dx >= term.line.max.x)
			termputc('\n');
		else{
			/* white out the space, just because */
			rect = term.line;
			rect.max.x = rect.min.x + dx;
			memimagedraw(term.screen, rect, term.bg, ZP, memopaque, ZP, S);
			term.line.min.x += dx;
			addflush(rect);
		}
		break;
	case '\b':
		if(term.line.min.x <= term.text.min.x)
			break;
		/* white out the backspaced letter */
		term.line.min.x -= term.spacex;
		rect = term.line;
		rect.max.x = rect.min.x + term.spacex;
		memimagedraw(term.screen, rect, term.bg, ZP, memopaque, ZP, S);
		addflush(rect);
		break;
	default:
		n = runetochar(buf, &r);
		buf[n] = 0;
		dx = memsubfontwidth(term.font, buf).x;
		if(term.line.min.x+dx > term.line.max.x)
			termputc('\n');
		rect = term.line;
		term.line.min.x += dx;
		rect.max.x = term.line.min.x;
		memimagedraw(term.screen, rect, term.bg, ZP, memopaque, ZP, S);
		memimagestring(term.screen, rect.min, term.fg, ZP, term.font, buf);
		addflush(rect);
		break;
	}
}

static void
_termputs(char *s, int n)
{
	int i, locked;
	Rune r;
	int nb;
	char *p, *ep;
	int mopen;

	if(term.screen == nil)
		return;
	locked = 0;
	for(i=0; i<100; i++){
		locked = drawcanqlock();
		if(locked)
			break;
		microdelay(100);
	}
	mopen = mouseopened();
	if(!mopen)
		termcursor(0);
	for(p=s, ep=s+n; p<ep; p+=nb){
		nb = chartorune(&r, p);
		if(nb <= 0){
			nb = 1;
			continue;
		}
		termputc(r);
	}
	if(!mopen)
		termcursor(1);
	flushmemscreen(term.flushr);
	term.flushr = Rect(10000, 10000, -10000, -10000);
	if(locked)
		drawqunlock();
}

static void
termputs(char *s, int n)
{
	if(n){
		char *old;
		lock(&term.lk);
		old = term.lputs;
		term.lputs = malloc(n+1);
		term.ln = n;
		strncpy(term.lputs, s, n);
		_termputs(s, n);
		unlock(&term.lk);		
		if(old)
			free(old);
	}
}

#if 0
static void
showkmesg(void)
{
	int n, nb;
	char buf[512], *p, *ep;
	Rune r;

	n = tailkmesg(buf, sizeof buf);
	if(n > 0){
		if(n < sizeof buf || (p = memchr(buf, '\n', n)) == nil)
			p = buf;
		/* can't call termputs - drawqlock is held */
		for(ep=p+n; p<ep; p+=nb){
			nb = chartorune(&r, p);
			if(nb <= 0){
				nb = 1;
				continue;
			}
			termputc(r);
		}
	}
}
#endif

static void
kickscreen(void)
{
	Rectangle r;
	ulong chan;
	int depth;
	int width;
	int softscreen;
	
	attachscreen(&r, &chan, &depth, &width, &softscreen, nil);
	termreplacescreenimage(gscreen);
}
